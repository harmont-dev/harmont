//! Disk-backed spool. Write path; read/replay added in Task 6.

use crate::error::AgentError;
use crate::pb;
use prost::Message;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

const SPOOL_BIN: &str = "spool.bin";
const SPOOL_ACK: &str = "spool.ack";

pub struct Spool {
    dir: PathBuf,
    bin: File,
    bytes_written: u64,
    chunks_since_fsync: u32,
    max_bytes: u64,
}

const FSYNC_EVERY_N: u32 = 64;

// Write-path API is exercised by the test suite; main-integration comes in a later task.
#[allow(dead_code)]
impl Spool {
    pub fn open(dir: impl AsRef<Path>) -> Result<Self, AgentError> {
        let dir = dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&dir)?;

        let bin_path = dir.join(SPOOL_BIN);
        let bin = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(&bin_path)?;

        let ack_path = dir.join(SPOOL_ACK);
        if !ack_path.exists() {
            let mut ack = File::create(&ack_path)?;
            ack.write_all(&0u64.to_le_bytes())?;
            ack.sync_all()?;
        }

        let bytes_written = std::fs::metadata(&bin_path)?.len();

        Ok(Spool {
            dir,
            bin,
            bytes_written,
            chunks_since_fsync: 0,
            max_bytes: u64::MAX,
        })
    }

    pub fn append(&mut self, chunk: &pb::LogChunk) -> Result<(), AgentError> {
        let mut body = Vec::with_capacity(chunk.encoded_len());
        chunk
            .encode(&mut body)
            .map_err(|e| AgentError::Spool(e.to_string()))?;
        let len: u32 = body
            .len()
            .try_into()
            .map_err(|_| AgentError::Spool("chunk too large for u32 length prefix".into()))?;

        self.bin.write_all(&chunk.seq.to_le_bytes())?;
        self.bin.write_all(&len.to_le_bytes())?;
        self.bin.write_all(&body)?;
        self.bytes_written += 8 + 4 + body.len() as u64;

        self.chunks_since_fsync += 1;
        if self.chunks_since_fsync >= FSYNC_EVERY_N {
            self.bin.sync_data()?;
            self.chunks_since_fsync = 0;
        }
        Ok(())
    }

    pub fn bytes_on_disk(&self) -> u64 {
        self.bytes_written
    }

    pub fn acked_seq(&self) -> u64 {
        let path = self.dir.join(SPOOL_ACK);
        match std::fs::read(&path) {
            Ok(bytes) if bytes.len() >= 8 => {
                let mut buf = [0u8; 8];
                buf.copy_from_slice(&bytes[..8]);
                u64::from_le_bytes(buf)
            }
            _ => 0,
        }
    }

    pub fn set_acked_seq(&mut self, seq: u64) -> Result<(), AgentError> {
        let path = self.dir.join(SPOOL_ACK);
        let tmp = self.dir.join("spool.ack.tmp");
        std::fs::write(&tmp, seq.to_le_bytes())?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }

    pub fn iter_from(&self, after_seq: u64) -> Result<SpoolIter, AgentError> {
        let path = self.dir.join(SPOOL_BIN);
        let f = File::open(&path)?;
        Ok(SpoolIter { reader: std::io::BufReader::new(f), after_seq })
    }

    pub fn open_with_cap(dir: impl AsRef<Path>, max_bytes: u64) -> Result<Self, AgentError> {
        let mut s = Self::open(dir)?;
        s.max_bytes = max_bytes;
        Ok(s)
    }

    /// The highest seq currently on disk. Returns 0 if the spool is empty.
    /// O(n) walk over the spool file; called only on session boundaries.
    pub fn max_persisted_seq(&self) -> Result<u64, AgentError> {
        let mut max = 0u64;
        for chunk in self.iter_from(0)? {
            let c = chunk?;
            if c.seq > max {
                max = c.seq;
            }
        }
        Ok(max)
    }

    /// If on-disk size exceeds max_bytes, rewrite the spool keeping only
    /// the most-recent half. If any dropped chunks were beyond `acked_seq`,
    /// emit a synthetic META "log truncated" chunk taking the next seq.
    pub fn maybe_rotate(&mut self) -> Result<(), AgentError> {
        if self.bytes_written <= self.max_bytes {
            return Ok(());
        }
        let acked = self.acked_seq();
        let target_bytes = self.max_bytes / 2;

        let all: Vec<pb::LogChunk> = self
            .iter_from(0)?
            .collect::<Result<_, _>>()?;

        if all.is_empty() {
            return Ok(());
        }

        let mut tail_chunks: Vec<pb::LogChunk> = Vec::new();
        let mut running = 0u64;
        for c in all.iter().rev() {
            let record_size = 12 + c.encoded_len() as u64;
            if running + record_size > target_bytes && !tail_chunks.is_empty() {
                break;
            }
            running += record_size;
            tail_chunks.push(c.clone());
        }
        tail_chunks.reverse();

        let kept_first_seq = tail_chunks.first().map(|c| c.seq).unwrap_or(0);
        let dropped_unacked = kept_first_seq > acked.saturating_add(1);

        let max_seq = all.iter().map(|c| c.seq).max().unwrap_or(0);
        let sentinel_seq = max_seq + 1;
        let sentinel = if dropped_unacked {
            let dropped = kept_first_seq.saturating_sub(acked + 1);
            Some(pb::LogChunk {
                seq: sentinel_seq,
                ts_unix_ns: 0,
                stream: pb::log_chunk::Stream::Meta as i32,
                data: format!("<harmont: log truncated, {dropped} chunks dropped>\n")
                    .into_bytes(),
            })
        } else {
            None
        };

        // Rewrite spool.bin atomically.
        let tmp = self.dir.join("spool.bin.tmp");
        {
            let mut f = OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&tmp)?;
            for c in &tail_chunks {
                Self::write_record(&mut f, c)?;
            }
            if let Some(s) = &sentinel {
                Self::write_record(&mut f, s)?;
            }
            f.sync_all()?;
        }
        std::fs::rename(&tmp, self.dir.join(SPOOL_BIN))?;

        // Reopen the underlying file handle.
        self.bin = OpenOptions::new()
            .append(true)
            .read(true)
            .open(self.dir.join(SPOOL_BIN))?;
        self.bytes_written = std::fs::metadata(self.dir.join(SPOOL_BIN))?.len();
        self.chunks_since_fsync = 0;
        Ok(())
    }

    fn write_record(f: &mut File, chunk: &pb::LogChunk) -> Result<(), AgentError> {
        let mut body = Vec::with_capacity(chunk.encoded_len());
        chunk.encode(&mut body).map_err(|e| AgentError::Spool(e.to_string()))?;
        let len: u32 = body.len().try_into()
            .map_err(|_| AgentError::Spool("chunk too large".into()))?;
        f.write_all(&chunk.seq.to_le_bytes())?;
        f.write_all(&len.to_le_bytes())?;
        f.write_all(&body)?;
        Ok(())
    }
}

pub struct SpoolIter {
    reader: std::io::BufReader<File>,
    after_seq: u64,
}

impl Iterator for SpoolIter {
    type Item = Result<pb::LogChunk, AgentError>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let mut header = [0u8; 12];
            match self.reader.read_exact(&mut header) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return None,
                Err(e) => return Some(Err(AgentError::Io(e))),
            }
            let seq = u64::from_le_bytes(header[0..8].try_into().unwrap());
            let len = u32::from_le_bytes(header[8..12].try_into().unwrap()) as usize;
            let mut body = vec![0u8; len];
            if let Err(e) = self.reader.read_exact(&mut body) {
                return Some(Err(AgentError::Io(e)));
            }
            if seq <= self.after_seq {
                continue;
            }
            match pb::LogChunk::decode(&body[..]) {
                Ok(c) => return Some(Ok(c)),
                Err(e) => return Some(Err(AgentError::Spool(e.to_string()))),
            }
        }
    }
}

impl Drop for Spool {
    fn drop(&mut self) {
        let _ = self.bin.sync_data();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn sample_chunk(seq: u64, data: &[u8]) -> pb::LogChunk {
        pb::LogChunk {
            seq,
            ts_unix_ns: 1_000_000_000 * 1_700_000_000 + seq as i64,
            stream: pb::log_chunk::Stream::Stdout as i32,
            data: data.to_vec(),
        }
    }

    #[test]
    fn open_creates_files_in_empty_dir() {
        let dir = TempDir::new().unwrap();
        let _ = Spool::open(dir.path()).expect("open should succeed");
        assert!(dir.path().join(SPOOL_BIN).exists());
        assert!(dir.path().join(SPOOL_ACK).exists());
    }

    #[test]
    fn append_writes_record() {
        let dir = TempDir::new().unwrap();
        let mut s = Spool::open(dir.path()).unwrap();
        s.append(&sample_chunk(1, b"hello\n")).unwrap();
        let size = std::fs::metadata(dir.path().join(SPOOL_BIN)).unwrap().len();
        assert!(size >= 12 + 6, "spool.bin too small: {} bytes", size);
        assert_eq!(s.bytes_on_disk(), size);
    }

    #[test]
    fn multiple_appends_grow_monotonically() {
        let dir = TempDir::new().unwrap();
        let mut s = Spool::open(dir.path()).unwrap();
        s.append(&sample_chunk(1, b"a")).unwrap();
        let after1 = s.bytes_on_disk();
        s.append(&sample_chunk(2, b"bb")).unwrap();
        let after2 = s.bytes_on_disk();
        assert!(after2 > after1);
    }

    #[test]
    fn replay_returns_appended_chunks_in_order() {
        let dir = TempDir::new().unwrap();
        let mut s = Spool::open(dir.path()).unwrap();
        s.append(&sample_chunk(1, b"a")).unwrap();
        s.append(&sample_chunk(2, b"bb")).unwrap();
        s.append(&sample_chunk(3, b"ccc")).unwrap();
        drop(s);

        let s2 = Spool::open(dir.path()).unwrap();
        let got: Vec<_> = s2.iter_from(0).unwrap().collect::<Result<_, _>>().unwrap();
        assert_eq!(got.len(), 3);
        assert_eq!(got[0].seq, 1);
        assert_eq!(got[0].data, b"a");
        assert_eq!(got[2].seq, 3);
        assert_eq!(got[2].data, b"ccc");
    }

    #[test]
    fn replay_respects_after_seq() {
        let dir = TempDir::new().unwrap();
        let mut s = Spool::open(dir.path()).unwrap();
        for i in 1..=5 {
            s.append(&sample_chunk(i, format!("{i}").as_bytes())).unwrap();
        }
        drop(s);

        let s2 = Spool::open(dir.path()).unwrap();
        let got: Vec<_> = s2.iter_from(3).unwrap().collect::<Result<_, _>>().unwrap();
        assert_eq!(got.iter().map(|c| c.seq).collect::<Vec<_>>(), vec![4, 5]);
    }

    #[test]
    fn ack_persists_across_reopen() {
        let dir = TempDir::new().unwrap();
        {
            let mut s = Spool::open(dir.path()).unwrap();
            s.set_acked_seq(42).unwrap();
        }
        let s2 = Spool::open(dir.path()).unwrap();
        assert_eq!(s2.acked_seq(), 42);
    }

    #[test]
    fn fresh_spool_acked_seq_is_zero() {
        let dir = TempDir::new().unwrap();
        let s = Spool::open(dir.path()).unwrap();
        assert_eq!(s.acked_seq(), 0);
    }

    #[test]
    fn rotates_when_over_cap_and_emits_sentinel_for_unacked() {
        let dir = TempDir::new().unwrap();
        let mut s = Spool::open_with_cap(dir.path(), 2048).unwrap();
        // No ack yet, so any rotation must emit a sentinel.
        for i in 1..=100 {
            s.append(&sample_chunk(i, &[b'x'; 64])).unwrap();
        }
        s.maybe_rotate().unwrap();
        assert!(s.bytes_on_disk() <= 2048 * 2, "rotation did not bound size: {}", s.bytes_on_disk());

        // Sentinel should be readable as a META chunk with the loss notice.
        let chunks: Vec<_> = s.iter_from(0).unwrap().collect::<Result<_, _>>().unwrap();
        let sentinel = chunks.iter().find(|c| {
            c.stream == pb::log_chunk::Stream::Meta as i32
                && std::str::from_utf8(&c.data).map(|s| s.contains("log truncated")).unwrap_or(false)
        });
        assert!(sentinel.is_some(), "no sentinel META chunk after rotation");
    }

    #[test]
    fn max_persisted_seq_returns_highest_seq() {
        let dir = TempDir::new().unwrap();
        let mut s = Spool::open(dir.path()).unwrap();
        assert_eq!(s.max_persisted_seq().unwrap(), 0);
        s.append(&sample_chunk(1, b"a")).unwrap();
        s.append(&sample_chunk(2, b"b")).unwrap();
        s.append(&sample_chunk(5, b"c")).unwrap();
        assert_eq!(s.max_persisted_seq().unwrap(), 5);
    }
}
