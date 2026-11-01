{ kubectl, fetchFromGitHub }:
# Keep the client within the supported version skew of talos/talconfig.yaml.
kubectl.overrideAttrs (
  finalAttrs: _previousAttrs: {
    version = "1.35.10";
    src = fetchFromGitHub {
      owner = "kubernetes";
      repo = "kubernetes";
      tag = "v${finalAttrs.version}";
      hash = "sha256-LaqG0zNn43JEt04isr8MTtLdH+M59EZcWpC0o64U2FY=";
    };
  }
)
