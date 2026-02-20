package handler

import (
	"net/http"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/scripts"
)

// GetCLIScript handles GET /api/v1/cli/identity-ssh-sign
// Serves the embedded identity-ssh-sign shell script as a download.
// No authentication required — the script contains no secrets.
func (h *Handler) GetCLIScript(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/x-sh")
	w.Header().Set("Content-Disposition", "attachment; filename=identity-ssh-sign")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(scripts.Script) //nolint:gosec // Not HTML output; shell script download with Content-Disposition: attachment
}
