defmodule Harmont.TestSupport.Rsa do
  @moduledoc """
  Provides a static 2048-bit RSA private key PEM for use in unit tests.

  TEST ONLY — this key was generated solely for automated tests and is not a
  real secret. Never use it for anything outside the test suite.
  Generated with: openssl genrsa 2048
  """

  @private_pem """
  -----BEGIN PRIVATE KEY-----
  MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC+81Wl5IGntG0q
  7qZ48Qu56mQXCpJ0P+l5aEcR6T3GPDT6hjPqkBZ64GDYEj/qjVBPeLP5k5wtvF60
  N/eay839swWzVVjM0iGuvmBhTS5bn7aABClhJdjgIJvmjOSEsLZdsvZawQ06pP3T
  yQRn69t4iTv9L+NqWI//cLuOm6cImMJj02QNRR3WC2KpiX3VZhVhXEUARiNhPxlQ
  wIn/DDqVOR7xFOei+Ya/6YtIwvA0H/Bz2wEvQMkJizPxSQDdJeiuakX8Q/Zn3SkK
  34DqTMs6cKnnAa2c/VuK7/lEk5q1x/xG2f58E+eXOnjDtgjWQH8dblsS4O5SN1CV
  W9fVWEnxAgMBAAECggEACvVJ+AA6FJa9IRabBRvIMX4rCkt4BiXYzzfVxEhfXC3+
  WFY1SoPEVn7j7+J0OpCriDQEGBGJh/JkePExS3fgtWt9q0H9m5t/hVi1jT/xph5v
  Sb9zZHjYjlwwtjVls9u0S4JGswSbLr9jNbE2iIQ3jx5JDAmggmzcrqsYiGGUX2DT
  ZOhjCP01SP3HKeZrnD0YVvYBo/VxUP/6jNpgJsxtBWo7w5vShCZpxWMcdMlV/oiT
  j4XKnQgqCjIsinA6J16W+kdtGIqU5NzWLbSprLmAZli7Zg4kdq7Iw9cA+jr5xV+j
  JFY8xvcWglwrmUugQP6/2Q3Zyhj45InjmTKhH8KpcQKBgQDxqWJqsJxMQ/WbUM22
  e8KM1iHLY18Qc5m1X9Py2mLht8ZLX/w5RBQmwBN9T+yVB/vlLpGN/cKQSVXU2g7P
  1W8WDYlzkHvVBxS9DTeHbjiIX/7zLpvs6dtv6uiWZ8GSHs8WVWQTQRjUYuhs7X9N
  IqT4yguTnF/EEjSzjCz0FEg6FQKBgQDKR7H7YNzwdaD3FWAgM2e7LpDPpucfjwNJ
  EOu0iUsWK5J3JH1X/tu3AKk1hqKSc6PvfhlRPWt/lYQTJ4LYxlG4OjSnrVosK6QS
  PdqomD8z9Ps598yREJJWLPF7JYTp3iR+e63LSw3C2tWN8v2n2hCtv/kmWhGamAkj
  dljddygTbQKBgQDlXEdtTUw60jF0hP+Jl/KxarbOa/UZDy6ux1HJZ957rsmEVohz
  7ZpWoOyefdHkLJy2CznYkyUrfn75MzDlrwPs4VI4ncP6Dutu9vFiF4mOXdYDBpS1
  CcvccA7qWXWN8rHH16nQ4HLpeSpx4AN3uU7sVg8gvUTjOghM9Njhm7JldQKBgQCE
  XuyK6zVKKj/e0V8pU1pzdKKRMNCYp1boDqmgaCP56yOa0gcweXhAxq70dxmWKxTB
  mcxpjH73a9mVS0rmHsnFfFmOzPNwalKhGVco8xCRKKTqp014NNb+i8Su6LuU66kI
  GFl/6qqjs98CWFxD5oD5ouIhhdl1SD7atQysSNix9QKBgEJ4uyVPQK3TsxJwWYHH
  1RHzkLXBSV0OERZ0f1CDCYtJtlYOYk5lGfZpCMP/Lq/UKodlR8bMOn40wvm0Adqt
  QgcTYSoB152VHTeQoXVFjmT7jFbTYK6i3rOC3O6JNpNtQYcRbQp4shnbLcUHOgOL
  xqr4q0K50IXHwV2yYOMMOMSr
  -----END PRIVATE KEY-----
  """

  @doc """
  Returns the test-only 2048-bit RSA private key PEM string.

  TEST ONLY — not a real secret, generated for unit tests.
  """
  @spec private_pem() :: String.t()
  def private_pem, do: String.trim(@private_pem)
end
