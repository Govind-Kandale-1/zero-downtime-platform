// Package migrations embeds the SQL schema so the binary carries it, the way
// the black-box app "runs migrations on startup".
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
