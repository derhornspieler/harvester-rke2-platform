package scripts

import _ "embed"

// Script contains the identity-ssh-sign CLI script, compiled into the binary.
//
//go:embed identity-ssh-sign
var Script []byte
