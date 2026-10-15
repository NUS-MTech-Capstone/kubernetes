package store

import (
	"context"
	"github.com/NUS-MTech-Capstone/session-manager/internal/model"
	"os"
	"testing"
	"time"
)

// This regression is intentionally red on deployed revision 9948d1e.
// A pod heartbeat can still report the runtime immediately after public close.
func TestPostgresCloseThenStaleHeartbeatMustReleaseCapacity(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Fatal("disposable TEST_DATABASE_URL is required")
	}
	ctx := context.Background()
	st := newTestPostgresStore(t, ctx, databaseURL)
	pod, err := st.RegisterPod(ctx, model.ProxyPod{PodID: "cleanup-repro", InstanceID: "boot-one", WebsocketURL: "ws://fixture", MaxSessions: 50})
	if err != nil {
		t.Fatal(err)
	}
	session, err := st.CreateSession(ctx, model.CreateSessionRequest{UserID: "fixture", HostID: "fixture", CRID: "fixture", ConnectionType: "ssh"}, time.Minute, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	closeRequest := model.CloseSessionRequest{OwnerPodID: pod.PodID, OwnerInstanceID: pod.InstanceID}
	if _, err = st.CloseSession(ctx, session.SessionID, closeRequest); err != nil {
		t.Fatal(err)
	}
	// The runtime has not yet observed closure when this heartbeat is sampled.
	pod.ActiveSessions = 1
	if _, err = st.HeartbeatPod(ctx, pod); err != nil {
		t.Fatal(err)
	}
	// Runtime subsequently closes and retries the idempotent session close.
	if _, err = st.CloseSession(ctx, session.SessionID, closeRequest); err != nil {
		t.Fatal(err)
	}
	pod.ActiveSessions = 0
	for i := 0; i < 3; i++ {
		if _, err = st.HeartbeatPod(ctx, pod); err != nil {
			t.Fatal(err)
		}
	}
	active, err := st.ListSessions(ctx, model.ListSessionsFilter{Status: model.SessionStatusActive})
	if err != nil {
		t.Fatal(err)
	}
	available, err := st.AvailablePods(ctx, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if len(active) != 0 || len(available) != 1 {
		t.Fatalf("fixture state: active=%d available=%d", len(active), len(available))
	}
	t.Logf("Closed session metadata=%s; active metadata=%d; pod accounted active=%d", session.SessionID, len(active), available[0].ActiveSessions)
	if available[0].ActiveSessions != 0 {
		t.Fatalf("capacity leak: active metadata=0, accounted sessions=%d after repeated zero-runtime heartbeats", available[0].ActiveSessions)
	}
}
