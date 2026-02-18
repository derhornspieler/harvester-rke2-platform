package handler

import (
	"net/http"
	"sync"

	"go.uber.org/zap"
)

// Healthz is the liveness probe. Always returns 200.
func (h *Handler) Healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Readyz is the readiness probe. Checks Keycloak and Vault connectivity.
func (h *Handler) Readyz(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	type checkResult struct {
		name string
		err  error
	}

	var wg sync.WaitGroup
	results := make(chan checkResult, 2)

	wg.Add(2)

	go func() {
		defer wg.Done()
		results <- checkResult{name: "keycloak", err: h.KC.Healthy(ctx)}
	}()

	go func() {
		defer wg.Done()
		results <- checkResult{name: "vault", err: h.Vault.Healthy(ctx)}
	}()

	wg.Wait()
	close(results)

	status := map[string]string{}
	allHealthy := true

	for cr := range results {
		if cr.err != nil {
			status[cr.name] = "unavailable"
			allHealthy = false
			h.Logger.Warn("readiness check failed",
				zap.String("component", cr.name),
				zap.Error(cr.err),
			)
		} else {
			status[cr.name] = "ok"
		}
	}

	status["status"] = "ok"
	httpStatus := http.StatusOK
	if !allHealthy {
		status["status"] = "degraded"
		httpStatus = http.StatusServiceUnavailable
	}

	writeJSON(w, httpStatus, status)
}
