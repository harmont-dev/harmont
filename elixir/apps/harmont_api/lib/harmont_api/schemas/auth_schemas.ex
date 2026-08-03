defmodule HarmontApi.Schemas.AuthGoogleRequest do
  @moduledoc "Request body for `POST /api/v0/auth/google`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AuthGoogleRequest",
    description: "Google OAuth callback payload from the SPA.",
    type: :object,
    properties: %{
      code: %OpenApiSpex.Schema{
        type: :string,
        description: "The authorization code returned by Google to the SPA."
      },
      redirect_uri: %OpenApiSpex.Schema{
        type: :string,
        description: "The redirect URI the SPA used; must match the OAuth client config."
      }
    },
    required: [:code, :redirect_uri],
    example: %{
      "code" => "4/0Afg...",
      "redirect_uri" => "https://app.harmont.dev/auth/google/callback"
    }
  })
end

defmodule HarmontApi.Schemas.AuthGithubRequest do
  @moduledoc "Request body for `POST /api/v0/auth/github`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AuthGithubRequest",
    description: "GitHub OAuth callback payload from the SPA.",
    type: :object,
    properties: %{
      code: %OpenApiSpex.Schema{
        type: :string,
        description: "The authorization code returned by GitHub to the SPA."
      },
      redirect_uri: %OpenApiSpex.Schema{
        type: :string,
        description:
          "The redirect URI the SPA used on the authorize step; Assent must send " <>
            "the same value on the code exchange."
      }
    },
    required: [:code, :redirect_uri],
    example: %{
      "code" => "abc123def456",
      "redirect_uri" => "https://app.harmont.dev/auth/callback"
    }
  })
end

defmodule HarmontApi.Schemas.User do
  @moduledoc "A Harmont user as returned to authenticated clients."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "User",
    description: "The authenticated Harmont user.",
    type: :object,
    properties: %{
      uuid: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Stable user id."},
      email: %OpenApiSpex.Schema{type: :string, description: "The user's email address."},
      name: %OpenApiSpex.Schema{type: :string, nullable: true, description: "Display name."}
    },
    required: [:uuid, :email]
  })
end

defmodule HarmontApi.Schemas.AuthTokenResponse do
  @moduledoc "Response for a successful OAuth login: a session token + the user."
  require OpenApiSpex

  alias HarmontApi.Schemas.User

  OpenApiSpex.schema(%{
    title: "AuthTokenResponse",
    description: "A freshly minted session bearer token and the authenticated user.",
    type: :object,
    properties: %{
      token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw session bearer token. Send it as `Authorization: Bearer <token>`."
      },
      user: User
    },
    required: [:token, :user]
  })
end

defmodule HarmontApi.Schemas.PasskeySignupBeginRequest do
  @moduledoc "Request body for `POST /api/v0/auth/passkey/signup/begin`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeySignupBeginRequest",
    description: "Starts passkey sign-up: runs the access gate and emails a verification link.",
    type: :object,
    properties: %{
      email: %OpenApiSpex.Schema{type: :string, description: "The email to sign up with."},
      name: %OpenApiSpex.Schema{type: :string, description: "The new user's display name."}
    },
    required: [:email, :name],
    example: %{"email" => "alice@harmont.dev", "name" => "Alice"}
  })
end

defmodule HarmontApi.Schemas.PasskeySignupOptionsRequest do
  @moduledoc "Request body for `POST /api/v0/auth/passkey/signup/options`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeySignupOptionsRequest",
    description: "Exchanges a verification token for WebAuthn credential-creation options.",
    type: :object,
    properties: %{
      verification_token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw token from the verification email."
      }
    },
    required: [:verification_token]
  })
end

defmodule HarmontApi.Schemas.PasskeyChallengeResponse do
  @moduledoc "A stored WebAuthn challenge id plus the browser options payload."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeyChallengeResponse",
    description:
      "The server-side challenge id (correlate it on finalize) and the " <>
        "PublicKeyCredential*Options the browser WebAuthn API consumes.",
    type: :object,
    properties: %{
      challenge_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "Opaque id of the stored, single-use challenge. Echo it back on finalize."
      },
      options: %OpenApiSpex.Schema{
        type: :object,
        description: "The PublicKeyCredentialCreationOptions / RequestOptions for the browser.",
        additionalProperties: true
      }
    },
    required: [:challenge_id, :options]
  })
end

defmodule HarmontApi.Schemas.PasskeySignupFinalizeRequest do
  @moduledoc "Request body for `POST /api/v0/auth/passkey/signup/finalize`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeySignupFinalizeRequest",
    description: "Completes passkey sign-up by submitting the attestation for the challenge.",
    type: :object,
    properties: %{
      challenge_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "The challenge id returned by the options call."
      },
      verification_token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw verification token (consumed here)."
      },
      attestation: %OpenApiSpex.Schema{
        type: :object,
        description: "The WebAuthn attestation response from navigator.credentials.create.",
        additionalProperties: true
      }
    },
    required: [:challenge_id, :verification_token, :attestation]
  })
end

defmodule HarmontApi.Schemas.PasskeyLoginOptionsRequest do
  @moduledoc "Request body for `POST /api/v0/auth/passkey/login/options` (empty)."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeyLoginOptionsRequest",
    description: "Starts a discoverable-credential (passkey) login. No fields required.",
    type: :object,
    properties: %{},
    required: []
  })
end

defmodule HarmontApi.Schemas.PasskeyLoginFinalizeRequest do
  @moduledoc "Request body for `POST /api/v0/auth/passkey/login/finalize`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeyLoginFinalizeRequest",
    description: "Completes passkey login by submitting the assertion for the challenge.",
    type: :object,
    properties: %{
      challenge_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "The challenge id returned by the login-options call."
      },
      assertion: %OpenApiSpex.Schema{
        type: :object,
        description: "The WebAuthn assertion response from navigator.credentials.get.",
        additionalProperties: true
      }
    },
    required: [:challenge_id, :assertion]
  })
end

defmodule HarmontApi.Schemas.TokenResponse do
  @moduledoc "A bare session-token response (passkey login)."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TokenResponse",
    description: "A freshly minted session bearer token.",
    type: :object,
    properties: %{
      token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw session bearer token. Send it as `Authorization: Bearer <token>`."
      }
    },
    required: [:token]
  })
end

defmodule HarmontApi.Schemas.PasskeyRegisterOptionsResponse do
  @moduledoc "Response for `POST /api/v0/auth/passkey/register/options` (alias of the challenge response)."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeyRegisterOptionsResponse",
    description:
      "WebAuthn credential-creation options for adding a passkey to the current " <>
        "user, plus the server-side challenge id to echo back on finalize. " <>
        "`excludeCredentials` lists the user's already-registered authenticators.",
    type: :object,
    properties: %{
      challenge_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "Opaque id of the stored, single-use challenge. Echo it back on finalize."
      },
      options: %OpenApiSpex.Schema{
        type: :object,
        description: "The PublicKeyCredentialCreationOptions for the browser.",
        additionalProperties: true
      }
    },
    required: [:challenge_id, :options]
  })
end

defmodule HarmontApi.Schemas.PasskeyRegisterFinalizeRequest do
  @moduledoc "Request body for `POST /api/v0/auth/passkey/register/finalize`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PasskeyRegisterFinalizeRequest",
    description: "Completes adding a passkey by submitting the attestation for the challenge.",
    type: :object,
    properties: %{
      challenge_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "The challenge id returned by the register-options call."
      },
      attestation: %OpenApiSpex.Schema{
        type: :object,
        description: "The WebAuthn attestation response from navigator.credentials.create.",
        additionalProperties: true
      },
      nickname: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Optional human label for the new passkey."
      }
    },
    required: [:challenge_id, :attestation]
  })
end

defmodule HarmontApi.Schemas.Passkey do
  @moduledoc "A registered passkey as returned to authenticated clients."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Passkey",
    description: "A WebAuthn credential registered to the current user.",
    type: :object,
    properties: %{
      uuid: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Stable passkey id."},
      nickname: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Human label for the passkey."
      },
      aaguid: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The authenticator's AAGUID (model identifier), if reported."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the passkey was registered."
      },
      last_used_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the passkey was last used to authenticate, if ever."
      }
    },
    required: [:uuid, :created_at]
  })
end

defmodule HarmontApi.Schemas.CurrentUserResponse do
  @moduledoc "Response for `GET /api/v0/user`: the authenticated user."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CurrentUserResponse",
    description: "The authenticated Harmont user and their personal-org slug.",
    type: :object,
    properties: %{
      uuid: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Stable user id."},
      email: %OpenApiSpex.Schema{type: :string, description: "The user's email address."},
      name: %OpenApiSpex.Schema{type: :string, nullable: true, description: "Display name."},
      personal_org_slug: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Slug of the user's personal organization."
      }
    },
    required: [:uuid, :email]
  })
end

defmodule HarmontApi.Schemas.PasskeyListResponse do
  @moduledoc "Response for `GET /api/v0/user/passkeys`: the user's registered passkeys."
  require OpenApiSpex

  alias HarmontApi.Schemas.Passkey

  OpenApiSpex.schema(%{
    title: "PasskeyListResponse",
    description: "Every passkey registered to the current user.",
    type: :object,
    properties: %{
      passkeys: %OpenApiSpex.Schema{
        type: :array,
        items: Passkey,
        description: "The user's registered passkeys."
      }
    },
    required: [:passkeys]
  })
end

defmodule HarmontApi.Schemas.RecoverBeginRequest do
  @moduledoc "Request body for `POST /api/v0/auth/recover/begin`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RecoverBeginRequest",
    description:
      "Starts magic-link account recovery. Always 204 (never leaks account existence).",
    type: :object,
    properties: %{
      email: %OpenApiSpex.Schema{type: :string, description: "The email to recover access for."}
    },
    required: [:email],
    example: %{"email" => "alice@harmont.dev"}
  })
end

defmodule HarmontApi.Schemas.RecoverOptionsRequest do
  @moduledoc "Request body for `POST /api/v0/auth/recover/options`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RecoverOptionsRequest",
    description:
      "Validates a magic-link token (without consuming it) and returns WebAuthn " <>
        "credential-creation options to enroll a fresh passkey.",
    type: :object,
    properties: %{
      magic_link_token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw token from the recovery email."
      }
    },
    required: [:magic_link_token]
  })
end

defmodule HarmontApi.Schemas.RecoverFinalizeRequest do
  @moduledoc "Request body for `POST /api/v0/auth/recover/finalize`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RecoverFinalizeRequest",
    description:
      "Completes recovery: consumes the magic-link token + challenge, registers a " <>
        "new passkey, and mints a session token.",
    type: :object,
    properties: %{
      magic_link_token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw recovery token (consumed here)."
      },
      challenge_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "The challenge id returned by the recover-options call."
      },
      attestation: %OpenApiSpex.Schema{
        type: :object,
        description: "The WebAuthn attestation response from navigator.credentials.create.",
        additionalProperties: true
      }
    },
    required: [:magic_link_token, :challenge_id, :attestation]
  })
end

defmodule HarmontApi.Schemas.CliTransferRequest do
  @moduledoc "Request body for `POST /api/v0/auth/cli/transfer`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CliTransferRequest",
    description:
      "The SPA hands a fresh session token to a locally-running CLI that generated " <>
        "`nonce` and is polling the claim endpoint.",
    type: :object,
    properties: %{
      nonce: %OpenApiSpex.Schema{
        type: :string,
        description: "The opaque nonce the CLI generated and is polling claim with."
      }
    },
    required: [:nonce],
    example: %{"nonce" => "a7Kp...random"}
  })
end

defmodule HarmontApi.Schemas.CliClaimRequest do
  @moduledoc "Request body for `POST /api/v0/auth/cli/claim`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CliClaimRequest",
    description: "The CLI polls with its nonce to claim the session token the SPA transferred.",
    type: :object,
    properties: %{
      nonce: %OpenApiSpex.Schema{
        type: :string,
        description: "The nonce the CLI generated for this loopback handoff."
      }
    },
    required: [:nonce],
    example: %{"nonce" => "a7Kp...random"}
  })
end

defmodule HarmontApi.Schemas.CliCodeResponse do
  @moduledoc "Response for `POST /api/v0/auth/cli/code`: a human-typeable paste code."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CliCodeResponse",
    description: "A short, human-typeable code the user re-types into the CLI.",
    type: :object,
    properties: %{
      code: %OpenApiSpex.Schema{
        type: :string,
        description: "The single-use paste code. Valid for five minutes."
      }
    },
    required: [:code],
    example: %{"code" => "K7P2QR9MX3WZ4NTV"}
  })
end

defmodule HarmontApi.Schemas.CliRedeemRequest do
  @moduledoc "Request body for `POST /api/v0/auth/cli/redeem`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CliRedeemRequest",
    description: "The CLI redeems a paste code the user typed in, receiving the session token.",
    type: :object,
    properties: %{
      code: %OpenApiSpex.Schema{
        type: :string,
        description: "The paste code shown by the SPA."
      }
    },
    required: [:code],
    example: %{"code" => "K7P2QR9MX3WZ4NTV"}
  })
end

defmodule HarmontApi.Schemas.CliTokenResponse do
  @moduledoc "Response carrying just the raw session token (CLI claim / redeem)."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CliTokenResponse",
    description: "The raw session bearer token handed to the CLI.",
    type: :object,
    properties: %{
      token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw session bearer token. Send it as `Authorization: Bearer <token>`."
      }
    },
    required: [:token]
  })
end

defmodule HarmontApi.Schemas.UserUpdateRequest do
  @moduledoc "Request body for `PATCH /api/v0/user`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UserUpdateRequest",
    description: "Updates the current user's editable profile fields.",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{
        type: :string,
        description: "New display name.",
        minLength: 1,
        maxLength: 255
      }
    },
    required: [:name],
    example: %{"name" => "Ada Lovelace"}
  })
end

defmodule HarmontApi.Schemas.Error do
  @moduledoc "The stable Harmont error envelope returned for failed requests."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Error",
    description: "The Harmont error envelope.",
    type: :object,
    properties: %{
      error: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          type: %OpenApiSpex.Schema{type: :string, description: "Stable machine error type."},
          code: %OpenApiSpex.Schema{type: :string, description: "Catalog code."},
          message: %OpenApiSpex.Schema{type: :string, description: "Human-readable message."},
          doc_url: %OpenApiSpex.Schema{type: :string, description: "Docs link for this error."},
          request_id: %OpenApiSpex.Schema{
            type: :string,
            description: "Correlates with server logs/traces."
          }
        },
        required: [:type, :code, :message]
      }
    },
    required: [:error]
  })
end
