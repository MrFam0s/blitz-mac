package web

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const blitzImportEmail = "fixture@example.invalid"

func blitzImportCache(t *testing.T) {
	t.Helper()
	withFileSessionCache(t)
	t.Setenv("ASC_BYPASS_KEYCHAIN", "1")
	oldRoot := sessionSharedLockRoot
	root := t.TempDir()
	sessionSharedLockRoot = func() string { return root }
	t.Cleanup(func() { sessionSharedLockRoot = oldRoot })
}

func blitzImportBundle(token string, full bool) *SessionBundle {
	expiry := time.Now().UTC().Add(time.Hour)
	bundle := &SessionBundle{Kind: SessionBundleKind, Version: SessionBundleVersion,
		AppleID: blitzImportEmail, ExportedAt: time.Now().UTC(), Cookies: []SessionBundleCookie{
			{URL: "https://appstoreconnect.apple.com/", Name: "myacinfo", Value: token,
				Path: "/", Secure: true, HTTPOnly: true, Expires: &expiry},
		}}
	if full {
		bundle.Cookies = append(bundle.Cookies, SessionBundleCookie{URL: "https://developer.apple.com/",
			Name: "portal", Value: token + "-portal", Path: "/services-account", Secure: true, Expires: &expiry})
	}
	return bundle
}

func blitzImportPersist(t *testing.T, token string, full bool) persistedSession {
	t.Helper()
	session, _, err := blitzImportBundle(token, full).normalize(time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	session.ProviderID, session.Generation = 123, token+"-generation"
	if full {
		session.DeveloperTeamID = "DEVTEAM"
	}
	if err := withSessionEntryLock(webSessionCacheKey(blitzImportEmail), func() error {
		return writeSessionToFile(webSessionCacheKey(blitzImportEmail), session)
	}); err != nil {
		t.Fatal(err)
	}
	return session
}

func blitzImportFixtureValidator(_ context.Context, source persistedSession, provider, team string) blitzSessionAssessment {
	receipt := BlitzSessionImportResult{AppleID: source.UserEmail, ProviderID: provider,
		ASC:             BlitzSessionEvidence{"verified", "exact_account_and_provider_verified"},
		DeveloperPortal: BlitzSessionEvidence{"invalid", "developer_portal_auth_required"}}
	if len(source.Cookies["https://developer.apple.com/"]) != 0 {
		receipt.DeveloperPortal = BlitzSessionEvidence{"verified", "exact_provider_team_verified"}
		receipt.DeveloperTeamID = "DEVTEAM"
		source.DeveloperTeamID = "DEVTEAM"
	}
	source.ProviderID, source.Generation, source.UpdatedAt = 123, "validated-candidate", time.Now().UTC()
	for _, cookies := range source.Cookies {
		receipt.CookieCount += len(cookies)
	}
	return blitzSessionAssessment{receipt: receipt, session: source}
}

func blitzImportRun(t *testing.T, bundle *SessionBundle, validate blitzSessionValidator) BlitzSessionImportResult {
	t.Helper()
	result, err := importBlitzSession(context.Background(), BlitzSessionImportParams{
		Bundle: bundle, ExpectedProviderID: "PUBLIC-PROVIDER"}, validate)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func blitzImportSnapshot(t *testing.T) sessionFileState {
	t.Helper()
	state, err := captureFileSessionState(webSessionCacheKey(blitzImportEmail))
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestBlitzSessionImportPreservesCompleteCanonicalSession(t *testing.T) {
	for _, candidateFull := range []bool{false, true} {
		t.Run(map[bool]string{false: "partial browser", true: "equal capability browser"}[candidateFull], func(t *testing.T) {
			blitzImportCache(t)
			blitzImportPersist(t, "full-cli-secret", true)
			before := blitzImportSnapshot(t)
			result := blitzImportRun(t, blitzImportBundle("browser-secret", candidateFull), blitzImportFixtureValidator)
			if result.Outcome != "existingPreserved" || result.CanonicalChanged || result.DeveloperPortal.Status != "verified" {
				t.Fatalf("unexpected receipt: %+v", result)
			}
			if !reflect.DeepEqual(before, blitzImportSnapshot(t)) {
				t.Fatal("complete canonical session or last-session pointer changed")
			}
			raw, _ := json.Marshal(result)
			if strings.Contains(string(raw), "secret") {
				t.Fatal("receipt leaked credentials")
			}
		})
	}
}

func TestBlitzSessionImportUpgradesPartialWithoutMixingJars(t *testing.T) {
	blitzImportCache(t)
	blitzImportPersist(t, "old-cookie-only", false)
	result := blitzImportRun(t, blitzImportBundle("new-cookie-only", true), blitzImportFixtureValidator)
	if result.Outcome != "imported" || !result.CanonicalChanged || result.DeveloperTeamID != "DEVTEAM" {
		t.Fatalf("unexpected receipt: %+v", result)
	}
	stored, found, err := readSessionFromFile(webSessionCacheKey(blitzImportEmail))
	if err != nil || !found || stored.ProviderID != 123 || stored.DeveloperTeamID != "DEVTEAM" {
		t.Fatalf("scope was not persisted: %+v, %v", stored, err)
	}
	raw, _ := json.Marshal(stored)
	if strings.Contains(string(raw), "old-cookie-only") || !strings.Contains(string(raw), "new-cookie-only") {
		t.Fatal("cookies from different sessions were merged")
	}
}

func TestBlitzSessionImportSelectsExistingStrongerAccountWithoutChangingEitherJar(t *testing.T) {
	blitzImportCache(t)
	blitzImportPersist(t, "account-a", true)
	accountA := blitzImportSnapshot(t)
	other, _, _ := blitzImportBundle("account-b", true).normalize(time.Now().UTC())
	other.UserEmail = "other@example.invalid"
	other.ProviderID = 456
	otherKey := webSessionCacheKey(other.UserEmail)
	if err := withSessionEntryLock(otherKey, func() error { return writeSessionToFile(otherKey, other) }); err != nil {
		t.Fatal(err)
	}
	accountB, err := captureFileSessionState(otherKey)
	if err != nil {
		t.Fatal(err)
	}
	result := blitzImportRun(t, blitzImportBundle("partial-browser-a", false), blitzImportFixtureValidator)
	currentB, _ := captureFileSessionState(otherKey)
	selectedKey, found, err := readLastKeyFromFile()
	if result.Outcome != "existingPreserved" || result.Reason != "existing_session_selected" || result.CanonicalChanged ||
		!result.SelectionChanged || !found || selectedKey != webSessionCacheKey(blitzImportEmail) || err != nil {
		t.Fatalf("wrong selected account: %+v / %v", result, err)
	}
	if !reflect.DeepEqual(accountA.session, blitzImportSnapshot(t).session) || !reflect.DeepEqual(accountB.session, currentB.session) {
		t.Fatal("switching explicit account changed stored credentials")
	}
}

func TestBlitzSessionImportCanStoreASCOnlyWhenNoExistingSession(t *testing.T) {
	blitzImportCache(t)
	result := blitzImportRun(t, blitzImportBundle("first", false), blitzImportFixtureValidator)
	if result.Outcome != "imported" || result.ASC.Status != "verified" || result.DeveloperPortal.Status == "verified" {
		t.Fatalf("partial session was incorrectly rejected or claimed complete: %+v", result)
	}
}

func TestBlitzSessionImportKeepsUnverifiableExistingSession(t *testing.T) {
	blitzImportCache(t)
	blitzImportPersist(t, "existing", true)
	before := blitzImportSnapshot(t)
	result := blitzImportRun(t, blitzImportBundle("new", true), func(ctx context.Context, source persistedSession, provider, team string) blitzSessionAssessment {
		out := blitzImportFixtureValidator(ctx, source, provider, team)
		if source.Generation == "existing-generation" {
			out.receipt.ASC = BlitzSessionEvidence{"unverified", "network_unavailable"}
		}
		return out
	})
	if result.Outcome != "rejected" || result.Reason != "existing_session_unverified" || !reflect.DeepEqual(before, blitzImportSnapshot(t)) {
		t.Fatalf("unverified existing cache was replaced: %+v", result)
	}
}

func TestBlitzSessionImportReplacesOnlyProvenExpiredExistingIdentity(t *testing.T) {
	for _, reason := range []string{"session_expired", "apple_account_mismatch", "provider_mismatch"} {
		t.Run(reason, func(t *testing.T) {
			blitzImportCache(t)
			blitzImportPersist(t, "existing", false)
			before := blitzImportSnapshot(t)
			result := blitzImportRun(t, blitzImportBundle("new", true), func(ctx context.Context, source persistedSession, provider, team string) blitzSessionAssessment {
				out := blitzImportFixtureValidator(ctx, source, provider, team)
				if source.Generation == "existing-generation" {
					out.receipt.ASC = BlitzSessionEvidence{"invalid", reason}
				}
				return out
			})
			if reason == "session_expired" {
				if result.Outcome != "imported" {
					t.Fatalf("expired cache could not be replaced: %+v", result)
				}
			} else if result.Outcome != "rejected" || !reflect.DeepEqual(before, blitzImportSnapshot(t)) {
				t.Fatalf("identity mismatch was treated as expiration: %+v", result)
			}
		})
	}
}

func TestBlitzSessionImportConcurrentCLILoginWinsCAS(t *testing.T) {
	for _, initial := range []bool{false, true} {
		t.Run(map[bool]string{false: "created during validation", true: "replaced during validation"}[initial], func(t *testing.T) {
			blitzImportCache(t)
			if initial {
				blitzImportPersist(t, "initial", false)
			}
			var concurrent sessionFileState
			first := true
			result := blitzImportRun(t, blitzImportBundle("browser", true), func(ctx context.Context, source persistedSession, provider, team string) blitzSessionAssessment {
				if first {
					first = false
					blitzImportPersist(t, "concurrent-cli", true)
					concurrent = blitzImportSnapshot(t)
				}
				return blitzImportFixtureValidator(ctx, source, provider, team)
			})
			if result.Outcome != "conflict" || result.CanonicalChanged || !reflect.DeepEqual(concurrent, blitzImportSnapshot(t)) {
				t.Fatalf("parallel CLI login was lost: %+v", result)
			}
		})
	}
}

func TestBlitzSessionImportFailureRestoresSessionAndLastPointer(t *testing.T) {
	blitzImportCache(t)
	blitzImportPersist(t, "existing", false)
	before := blitzImportSnapshot(t)
	oldWrite := sessionFileWrite
	writes := 0
	sessionFileWrite = func(path string, file *os.File, data []byte, mode os.FileMode) error {
		writes++
		if writes == 2 {
			return errors.New("fixture last-pointer write failure")
		}
		return oldWrite(path, file, data, mode)
	}
	t.Cleanup(func() { sessionFileWrite = oldWrite })
	result := blitzImportRun(t, blitzImportBundle("new", true), blitzImportFixtureValidator)
	if result.Outcome != "rejected" || result.Reason != "session_commit_unavailable" || !reflect.DeepEqual(before, blitzImportSnapshot(t)) {
		t.Fatalf("failed commit changed existing state: %+v", result)
	}
}

func TestBlitzSessionImportDoesNotEraseIndependentKeychainSession(t *testing.T) {
	blitzImportCache(t)
	t.Setenv("ASC_BYPASS_KEYCHAIN", "0")
	t.Setenv(webSessionBackendEnv, "auto")
	mirror, _, err := blitzImportBundle("independent-cli", true).normalize(time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	mirror.ProviderID, mirror.DeveloperTeamID = 123, "DEVTEAM"
	key := webSessionCacheKey(blitzImportEmail)
	if err := writeMergedSessionToKeychain(key, mirror, nil); err != nil {
		t.Fatal(err)
	}
	blitzImportPersist(t, "file-partial", false)
	before := blitzImportSnapshot(t)
	result := blitzImportRun(t, blitzImportBundle("browser", true), blitzImportFixtureValidator)
	current, found, err := readSessionFromKeychain(key)
	if result.Outcome != "rejected" || result.Reason != "cache_backends_diverged" ||
		err != nil || !found || !reflect.DeepEqual(mirror, current) || !reflect.DeepEqual(before, blitzImportSnapshot(t)) {
		t.Fatalf("independent canonical/mirror session changed: %+v / %v", result, err)
	}
}

func TestBlitzSessionImportRejectsStalePersistedProviderBeforePortalRead(t *testing.T) {
	blitzImportCache(t)
	previous := sessionInfoFetcher
	t.Cleanup(func() { sessionInfoFetcher = previous })
	sessionInfoFetcher = func(context.Context, *http.Client) (*sessionInfo, error) {
		info := &sessionInfo{Provider: sessionProviderInfo{ProviderID: 123, PublicProviderID: "PUBLIC-PROVIDER"}}
		info.User.EmailAddress = blitzImportEmail
		return info, nil
	}
	source, _, _ := blitzImportBundle("fixture", true).normalize(time.Now().UTC())
	source.ProviderID = 456
	result := validateBlitzSession(context.Background(), source, "PUBLIC-PROVIDER", "")
	if result.receipt.ASC.Status != "invalid" || result.receipt.ASC.Reason != "provider_mismatch" {
		t.Fatalf("stale provider accepted: %+v", result.receipt)
	}
}

func TestBlitzSessionImportRejectsUnsafeFileAndUnavailableLock(t *testing.T) {
	for _, unsafeLock := range []bool{false, true} {
		t.Run(map[bool]string{false: "symlink cache", true: "unavailable lock"}[unsafeLock], func(t *testing.T) {
			blitzImportCache(t)
			outside := filepath.Join(t.TempDir(), "outside")
			if err := os.WriteFile(outside, []byte("preserve"), 0600); err != nil {
				t.Fatal(err)
			}
			if unsafeLock {
				sessionSharedLockRoot = func() string { return outside }
			} else {
				path, _ := webSessionFilePath(webSessionCacheKey(blitzImportEmail))
				if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, path); err != nil {
					t.Fatal(err)
				}
			}
			result := blitzImportRun(t, blitzImportBundle("candidate", true), blitzImportFixtureValidator)
			if result.Outcome != "rejected" || result.Reason != "session_cache_unavailable" {
				t.Fatalf("unsafe cache accepted: %+v", result)
			}
			raw, _ := os.ReadFile(outside)
			if string(raw) != "preserve" {
				t.Fatal("unrelated file changed")
			}
		})
	}
}

type blitzImportTransport func(*http.Request) (*http.Response, error)

func (f blitzImportTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestBlitzSessionImportValidatesIsolatedAccountProviderPortalAndCookieScopes(t *testing.T) {
	for _, scenario := range []string{"valid", "wrong_account", "wrong_provider", "wrong_team", "portal_expired", "portal_renewal", "portal_deleted", "asc_session_only", "portal_session_only"} {
		t.Run(scenario, func(t *testing.T) {
			blitzImportCache(t)
			oldTransport, oldFetcher := http.DefaultTransport, sessionInfoFetcher
			t.Cleanup(func() { http.DefaultTransport, sessionInfoFetcher = oldTransport, oldFetcher })
			portalReads := 0
			http.DefaultTransport = blitzImportTransport(func(r *http.Request) (*http.Response, error) {
				if r.URL.Host != "developer.apple.com" || r.URL.Path != developerPortalTeamsPath || r.Method != http.MethodPost {
					t.Fatalf("unexpected request: %s %s", r.Method, r.URL)
				}
				portalReads++
				status, body := 200, `{"teams":[{"teamId":"DEVTEAM","name":"Fixture Provider"}],"resultCode":0}`
				if scenario == "portal_expired" {
					status, body = 401, `{"error":"private-body-secret"}`
				}
				header := http.Header{}
				if scenario == "portal_renewal" {
					header.Add("Set-Cookie", "portal=rotated-portal; Path=/services-account; Secure; HttpOnly; Max-Age=1800")
				}
				if scenario == "portal_deleted" {
					header.Add("Set-Cookie", "portal=; Path=/services-account; Max-Age=-1")
				}
				if scenario == "portal_session_only" {
					header.Add("Set-Cookie", "portal=browser-only-portal; Path=/services-account; Secure")
				}
				return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: header, Request: r}, nil
			})
			sessionInfoFetcher = func(ctx context.Context, client *http.Client) (*sessionInfo, error) {
				origin, _ := url.Parse("https://appstoreconnect.apple.com/")
				cookie := client.Jar.Cookies(origin)
				if len(cookie) != 1 || cookie[0].Value != "browser-only" {
					t.Fatal("candidate jar contains another session")
				}
				info := &sessionInfo{Provider: sessionProviderInfo{ProviderID: 123, PublicProviderID: "PUBLIC-PROVIDER", Name: "Fixture Provider"}}
				info.User.EmailAddress = blitzImportEmail
				if scenario == "wrong_account" {
					info.User.EmailAddress = "other@example.invalid"
				}
				if scenario == "wrong_provider" {
					info.Provider.PublicProviderID = "OTHER-PROVIDER"
				}
				if scenario == "asc_session_only" {
					client.Jar.SetCookies(origin, []*http.Cookie{{Name: "myacinfo", Value: "browser-only", Path: "/", Secure: true}})
				}
				return info, nil
			}
			p := BlitzSessionImportParams{Bundle: blitzImportBundle("browser-only", true), ExpectedProviderID: "PUBLIC-PROVIDER"}
			if scenario == "wrong_team" {
				p.ExpectedDeveloperTeamID = "OTHERTEAM"
			}
			result, err := ImportBlitzSession(context.Background(), p)
			if err != nil {
				t.Fatal(err)
			}
			if scenario == "asc_session_only" {
				if result.Outcome != "rejected" || result.ASC.Reason != "candidate_serialization_failed" {
					t.Fatalf("bounded ASC credential became immortal: %+v", result)
				}
				if _, found, _ := readSessionFromFile(webSessionCacheKey(blitzImportEmail)); found {
					t.Fatal("unpersistable ASC session written to cache")
				}
				return
			}
			if strings.HasPrefix(scenario, "wrong_") {
				if result.Outcome != "rejected" {
					t.Fatalf("wrong identity accepted: %+v", result)
				}
				if scenario != "wrong_team" && portalReads != 0 {
					t.Fatal("Portal queried before ASC identity was proven")
				}
				return
			}
			if result.Outcome != "imported" || result.ASC.Status != "verified" || portalReads != 1 {
				t.Fatalf("candidate not imported: %+v", result)
			}
			if scenario == "portal_expired" && (result.DeveloperPortal.Status != "invalid" || result.DeveloperTeamID != "") {
				t.Fatalf("Portal authentication falsely claimed: %+v", result)
			}
			stored, _, _ := readSessionFromFile(webSessionCacheKey(blitzImportEmail))
			cookies := stored.Cookies["https://developer.apple.com/"]
			if scenario == "portal_deleted" || scenario == "portal_session_only" {
				if len(cookies) != 0 {
					t.Fatal("deleted/session-only Portal cookie became immortal")
				}
				if scenario == "portal_session_only" && (result.DeveloperPortal.Status != "unverified" || result.DeveloperTeamID != "") {
					t.Fatal("nonpersistable Portal credential falsely proved canonical access")
				}
				return
			}
			if len(cookies) != 1 || cookies[0].Path != "/services-account" || cookies[0].Expires.IsZero() {
				t.Fatalf("Portal cookie path/expiry lost: %+v", cookies)
			}
			if scenario == "portal_renewal" && (cookies[0].Value != "rotated-portal" || time.Until(cookies[0].Expires) > 31*time.Minute) {
				t.Fatal("Portal renewal lost value or deadline")
			}
			raw, _ := json.Marshal(result)
			if strings.Contains(string(raw), "browser-only") || strings.Contains(string(raw), "private-body-secret") {
				t.Fatal("private credentials/response leaked in receipt")
			}
		})
	}
}
