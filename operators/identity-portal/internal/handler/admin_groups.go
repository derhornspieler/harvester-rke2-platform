package handler

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// ListGroups handles GET /api/v1/admin/groups
func (h *Handler) ListGroups(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	groups, err := h.KC.GetGroups(ctx)
	if err != nil {
		h.Logger.Error("failed to list groups", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to list groups")
		return
	}

	writeJSON(w, http.StatusOK, groups)
}

// GetGroup handles GET /api/v1/admin/groups/{id}
func (h *Handler) GetGroup(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	groupID := pathParam(r, "id")

	if groupID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "group id is required")
		return
	}

	group, err := h.KC.GetGroup(ctx, groupID)
	if err != nil {
		h.Logger.Error("failed to get group", zap.Error(err), zap.String("group_id", groupID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "GROUP_NOT_FOUND", "group not found")
		return
	}

	// Fetch members.
	members, err := h.KC.GetGroupMembers(ctx, groupID)
	if err == nil {
		memberNames := make([]string, 0, len(members))
		for _, m := range members {
			memberNames = append(memberNames, m.Username)
		}
		group.Members = memberNames
	}

	writeJSON(w, http.StatusOK, group)
}

// CreateGroup handles POST /api/v1/admin/groups
func (h *Handler) CreateGroup(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req model.CreateGroupRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "name is required")
		return
	}

	groupID, err := h.KC.CreateGroup(ctx, req.Name)
	if err != nil {
		h.Logger.Error("failed to create group", zap.Error(err), zap.String("name", req.Name),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to create group")
		return
	}

	h.Logger.Info("group created",
		zap.String("group_id", groupID),
		zap.String("name", req.Name),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusCreated, map[string]string{"id": groupID})
}

// UpdateGroup handles PUT /api/v1/admin/groups/{id}
func (h *Handler) UpdateGroup(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	groupID := pathParam(r, "id")

	if groupID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "group id is required")
		return
	}

	var req model.UpdateGroupRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Name == nil || *req.Name == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "name is required")
		return
	}

	if err := h.KC.UpdateGroup(ctx, groupID, *req.Name); err != nil {
		h.Logger.Error("failed to update group", zap.Error(err), zap.String("group_id", groupID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to update group")
		return
	}

	h.Logger.Info("group updated",
		zap.String("group_id", groupID),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	w.WriteHeader(http.StatusNoContent)
}

// DeleteGroup handles DELETE /api/v1/admin/groups/{id}
func (h *Handler) DeleteGroup(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	groupID := pathParam(r, "id")

	if groupID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "group id is required")
		return
	}

	if err := h.KC.DeleteGroup(ctx, groupID); err != nil {
		h.Logger.Error("failed to delete group", zap.Error(err), zap.String("group_id", groupID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to delete group")
		return
	}

	h.Logger.Info("group deleted",
		zap.String("group_id", groupID),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	w.WriteHeader(http.StatusNoContent)
}

// AddGroupMember handles POST /api/v1/admin/groups/{id}/members
func (h *Handler) AddGroupMember(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	groupID := pathParam(r, "id")

	if groupID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "group id is required")
		return
	}

	var req model.GroupMembershipRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.UserID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "user_id is required")
		return
	}

	if err := h.KC.AddUserToGroup(ctx, req.UserID, groupID); err != nil {
		h.Logger.Error("failed to add member to group", zap.Error(err),
			zap.String("group_id", groupID), zap.String("user_id", req.UserID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to add member to group")
		return
	}

	h.Logger.Info("member added to group",
		zap.String("group_id", groupID),
		zap.String("user_id", req.UserID),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	w.WriteHeader(http.StatusNoContent)
}

// RemoveGroupMember handles DELETE /api/v1/admin/groups/{id}/members/{userId}
func (h *Handler) RemoveGroupMember(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	groupID := pathParam(r, "id")
	userID := pathParam(r, "userId")

	if groupID == "" || userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "group id and user id are required")
		return
	}

	if err := h.KC.RemoveUserFromGroup(ctx, userID, groupID); err != nil {
		h.Logger.Error("failed to remove member from group", zap.Error(err),
			zap.String("group_id", groupID), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to remove member from group")
		return
	}

	h.Logger.Info("member removed from group",
		zap.String("group_id", groupID),
		zap.String("user_id", userID),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	w.WriteHeader(http.StatusNoContent)
}
