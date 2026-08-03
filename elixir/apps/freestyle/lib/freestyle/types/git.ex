defmodule Freestyle.Types.Git do
  @moduledoc "Git repository payload schemas."

  defmodule Repository do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            visibility: String.t(),
            default_branch: term(),
            created_at: String.t() | nil
          }

    embedded_schema do
      field(:id, :string)
      field(:name, :string)
      field(:visibility, :string)
      field(:default_branch, :map)
      field(:created_at, :string)
    end

    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      {:ok,
       %__MODULE__{
         id: json["id"],
         name: json["name"],
         visibility: json["visibility"],
         default_branch: json["defaultBranch"],
         created_at: json["createdAt"]
       }}
    end
  end

  defmodule CreateRepoOpts do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            name: String.t() | nil,
            public: boolean(),
            default_branch: String.t() | nil
          }

    embedded_schema do
      field(:name, :string)
      field(:public, :boolean, default: false)
      field(:default_branch, :string)
    end

    @spec encode(t()) :: map()
    def encode(%__MODULE__{} = o) do
      %{"name" => o.name, "public" => o.public, "defaultBranch" => o.default_branch}
      |> Map.reject(fn {_, v} -> is_nil(v) end)
    end
  end

  defmodule CommitFile do
    use Freestyle.Schema

    @type t :: %__MODULE__{path: String.t(), content: String.t(), delete: boolean() | nil}

    embedded_schema do
      field(:path, :string)
      field(:content, :string)
      field(:delete, :boolean)
    end
  end

  defmodule CreateCommitOpts do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            branch: String.t(),
            message: String.t(),
            files: [CommitFile.t()],
            expected_sha: String.t() | nil
          }

    embedded_schema do
      field(:branch, :string)
      field(:message, :string)
      embeds_many(:files, CommitFile)
      field(:expected_sha, :string)
    end

    @spec encode(t()) :: map()
    def encode(%__MODULE__{} = o) do
      %{
        "branch" => o.branch,
        "message" => o.message,
        "files" => Enum.map(o.files, &CommitFile.encode/1),
        "expectedSha" => o.expected_sha
      }
      |> Map.reject(fn {_, v} -> is_nil(v) end)
    end
  end

  defmodule CommitResult do
    use Freestyle.Schema
    @type t :: %__MODULE__{sha: String.t()}

    embedded_schema do
      field(:sha, :string)
    end

    @doc ~S(Unwrap the API's `{"commit": {"sha": ...}}` response.)
    @spec decode_wrapped(map()) :: {:ok, t()} | {:error, String.t()}
    def decode_wrapped(%{"commit" => commit}) when is_map(commit), do: decode(commit)
    def decode_wrapped(_), do: {:error, "expected {\"commit\": {...}}"}
  end

  defmodule CommitObject do
    use Freestyle.Schema

    @type t :: %__MODULE__{sha: String.t(), message: String.t(), author: term()}

    embedded_schema do
      field(:sha, :string)
      field(:message, :string)
      field(:author, :map)
    end

    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      {:ok, %__MODULE__{sha: json["sha"], message: json["message"], author: json["author"]}}
    end
  end

  defmodule Branch do
    use Freestyle.Schema
    @type t :: %__MODULE__{name: String.t(), commit: String.t()}

    embedded_schema do
      field(:name, :string)
      field(:commit, :string)
    end

    @doc "Decode commit from `commit` or `sha`."
    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      {:ok, %__MODULE__{name: json["name"], commit: json["commit"] || json["sha"]}}
    end

    @spec encode(t()) :: map()
    def encode(%__MODULE__{name: name, commit: commit}), do: %{"name" => name, "commit" => commit}
  end

  defmodule Tag do
    use Freestyle.Schema
    @type t :: %__MODULE__{name: String.t(), commit: String.t()}

    embedded_schema do
      field(:name, :string)
      field(:commit, :string)
    end

    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      {:ok, %__MODULE__{name: json["name"], commit: json["commit"] || json["sha"]}}
    end
  end

  defmodule TreeEntry do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            path: String.t(),
            mode: String.t(),
            type: String.t(),
            sha: String.t()
          }

    embedded_schema do
      field(:path, :string)
      field(:mode, :string)
      field(:type, :string)
      field(:sha, :string)
    end
  end

  defmodule TreeObject do
    use Freestyle.Schema
    alias Freestyle.Types.Git.TreeEntry

    @type t :: %__MODULE__{sha: String.t(), entries: [TreeEntry.t()]}

    embedded_schema do
      field(:sha, :string)
      embeds_many(:entries, TreeEntry)
    end

    @doc "Decode, hand-rolling the embedded entries (cast/3 can't cast embeds)."
    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      with {:ok, entries} <- TreeEntry.decode_list(json["entries"] || []) do
        {:ok, %__MODULE__{sha: json["sha"], entries: entries}}
      end
    end
  end

  defmodule BlobObject do
    use Freestyle.Schema
    @type t :: %__MODULE__{sha: String.t(), content: String.t(), size: integer()}

    embedded_schema do
      field(:sha, :string)
      field(:content, :string)
      field(:size, :integer)
    end
  end

  defmodule GitContents do
    @moduledoc "File-or-directory sum type for the contents endpoint."
    alias Freestyle.Types.Git.TreeEntry

    @type t ::
            {:file, %{content: String.t(), sha: String.t()}}
            | {:directory, [TreeEntry.t()]}

    @doc "Decode: `content`+`sha` → file; otherwise `entries` → directory."
    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(%{"content" => content, "sha" => sha}) do
      {:ok, {:file, %{content: content, sha: sha}}}
    end

    def decode(%{"entries" => entries}) when is_list(entries) do
      with {:ok, decoded} <- TreeEntry.decode_list(entries), do: {:ok, {:directory, decoded}}
    end

    def decode(_), do: {:error, "expected file (content+sha) or directory (entries)"}
  end

  defmodule GitTrigger do
    use Freestyle.Schema
    @type t :: %__MODULE__{id: String.t(), url: String.t() | nil}

    embedded_schema do
      field(:id, :string)
      field(:url, :string)
    end

    @doc "Decode url from `url` or `trigger`."
    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      {:ok, %__MODULE__{id: json["id"], url: json["url"] || json["trigger"]}}
    end
  end

  defmodule CreateTriggerOpts do
    use Freestyle.Schema
    @type t :: %__MODULE__{trigger: String.t()}

    embedded_schema do
      field(:trigger, :string)
    end
  end

  defmodule GithubSyncConfig do
    use Freestyle.Schema
    @type t :: %__MODULE__{repo: String.t(), branch: String.t() | nil}

    embedded_schema do
      field(:repo, :string)
      field(:branch, :string)
    end
  end

  defmodule CommitList do
    alias Freestyle.Types.Git.CommitObject

    @type t :: %__MODULE__{commits: [CommitObject.t()], next_commit: String.t() | nil}
    defstruct commits: [], next_commit: nil

    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      with {:ok, commits} <- CommitObject.decode_list(json["commits"] || []) do
        {:ok, %__MODULE__{commits: commits, next_commit: json["nextCommit"]}}
      end
    end
  end

  defmodule ListCommitsParams do
    @type t :: %__MODULE__{
            branch: String.t() | nil,
            limit: integer() | nil,
            order: String.t() | nil,
            since: String.t() | nil,
            until: String.t() | nil
          }
    defstruct [:branch, :limit, :order, :since, :until]
  end
end
