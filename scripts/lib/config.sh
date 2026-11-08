# Helpers shared by the release scripts. Source this file. It defines functions only and changes nothing on its own.

# Prints the value of KEY in an xcconfig file, without the spaces around it. Prints nothing when the key is absent.
# Usage: xcconfig_value FILE KEY
xcconfig_value() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | head -n 1 | sed -e 's/[[:space:]]*$//'
}

# Prints the code-signing identity to use: MACFLEET_SIGN_IDENTITY when set, then Config/Signing.local.xcconfig (git-ignored),
# then the committed default "-", which signs ad hoc and needs no credential.
signing_identity() {
  if [ -n "${MACFLEET_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$MACFLEET_SIGN_IDENTITY"
    return 0
  fi
  if [ -f Config/Signing.local.xcconfig ]; then
    local_value=$(xcconfig_value Config/Signing.local.xcconfig CODE_SIGN_IDENTITY)
    if [ -n "$local_value" ]; then
      printf '%s\n' "$local_value"
      return 0
    fi
  fi
  xcconfig_value Config/Signing.xcconfig CODE_SIGN_IDENTITY
}
