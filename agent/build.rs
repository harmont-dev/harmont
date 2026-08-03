fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Use vendored protoc so builds succeed without a system protoc install.
    let protoc = protoc_bin_vendored::protoc_bin_path()?;
    // SAFETY: build scripts run single-threaded before the rest of the build;
    // no other threads exist that could observe a partially-written env var.
    unsafe {
        std::env::set_var("PROTOC", protoc);
    }

    let mut cfg = prost_build::Config::new();
    cfg.compile_protos(&["../proto/agent.proto"], &["../proto"])?;
    println!("cargo:rerun-if-changed=../proto/agent.proto");
    Ok(())
}
