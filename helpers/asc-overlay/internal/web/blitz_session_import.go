package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"reflect"
	"regexp"
	"strings"
	"time"
)

// BlitzSessionImportParams binds a fresh browser capture to the provider that
// the browser just confirmed. The portable bundle remains the upstream format.
// Neither cached provider metadata nor a caller-supplied Portal team is proof.
type BlitzSessionImportParams struct {
	Bundle                  *SessionBundle `json:"bundle"`
	ExpectedProviderID      string         `json:"expectedProviderId"`
	ExpectedDeveloperTeamID string         `json:"expectedDeveloperTeamId,omitempty"`
}

type BlitzSessionEvidence struct {
	Status string `json:"status"`
	Reason string `json:"reason"`
}

// The receipt deliberately contains no cookie values, raw HTTP errors or paths.
// Portal authentication is separate from agreement acceptance/release readiness.
type BlitzSessionImportResult struct {
	Outcome          string               `json:"outcome"`
	Reason           string               `json:"reason"`
	AppleID          string               `json:"appleId,omitempty"`
	ProviderID       string               `json:"providerId,omitempty"`
	DeveloperTeamID  string               `json:"developerTeamId,omitempty"`
	ASC              BlitzSessionEvidence `json:"asc"`
	DeveloperPortal  BlitzSessionEvidence `json:"developerPortal"`
	CanonicalChanged bool                 `json:"canonicalChanged"`
	SelectionChanged bool                 `json:"selectionChanged"`
	CookieCount      int                  `json:"cookieCount"`
}

type blitzSessionAssessment struct {
	receipt BlitzSessionImportResult
	session persistedSession
}

type blitzSessionValidator func(context.Context, persistedSession, string, string) blitzSessionAssessment

var blitzSessionScopeID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// ImportBlitzSession never mixes jars, refreshes the existing cache during its
// preflight, switches providers, logs in, or accepts agreements. The current
// canonical session wins whenever it is already at least as capable. A stale
// import cannot race a CLI login: validation happens outside the shared locks,
// then a byte-exact compare-and-swap protects all affected backends and pointers.
func ImportBlitzSession(ctx context.Context, p BlitzSessionImportParams) (BlitzSessionImportResult, error) {
	return importBlitzSession(ctx, p, validateBlitzSession)
}

func importBlitzSession(ctx context.Context, p BlitzSessionImportParams, validate blitzSessionValidator) (BlitzSessionImportResult, error) {
	if p.Bundle == nil || !blitzSessionScopeID.MatchString(p.ExpectedProviderID) ||
		(p.ExpectedDeveloperTeamID != "" && !blitzSessionScopeID.MatchString(p.ExpectedDeveloperTeamID)) {
		return BlitzSessionImportResult{}, errors.New("invalid web session import target")
	}
	raw, err := json.Marshal(p.Bundle)
	if err != nil || len(raw) > MaxSessionBundleSize {
		return BlitzSessionImportResult{}, errors.New("invalid web session bundle")
	}
	candidate, _, err := p.Bundle.normalize(time.Now().UTC())
	if err != nil {
		return BlitzSessionImportResult{}, errors.New("invalid web session bundle")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 75*time.Second)
	defer cancel()
	unknown := BlitzSessionEvidence{"unverified", "not_checked"}
	result := BlitzSessionImportResult{Outcome: "rejected", ASC: unknown, DeveloperPortal: unknown}
	selection := resolveBackendSelection()
	if selection.backend == sessionBackendOff {
		result.Reason = "session_cache_disabled"
		return result, nil
	}
	key := webSessionCacheKey(candidate.UserEmail)
	var before importedSessionState
	var existing persistedSession
	var exists bool
	err = withBlitzSessionImportLock(selection, key, func() error {
		var err error
		before, err = captureImportedSessionState(selection, key)
		if err != nil {
			return err
		}
		existing, exists, err = readSessionBySelection(selection, key)
		return err
	})
	if err != nil {
		result.Reason = "session_cache_unavailable"
		return result, nil
	}
	// An old or mismatched account cache is never treated as an empty cache.
	if exists && !strings.EqualFold(strings.TrimSpace(existing.UserEmail), candidate.UserEmail) {
		result.Reason = "existing_account_mismatch"
		return result, nil
	}
	checked := validate(ctx, candidate, p.ExpectedProviderID, p.ExpectedDeveloperTeamID)
	result = checked.receipt
	result.Outcome = "rejected"
	if result.ASC.Status != "verified" || result.DeveloperPortal.Reason == "developer_team_mismatch" {
		result.Reason = "candidate_session_not_verified"
		return result, nil
	}
	write := true
	if exists {
		current := validate(ctx, existing, p.ExpectedProviderID, p.ExpectedDeveloperTeamID)
		if existing.ProviderID != 0 && existing.ProviderID != checked.session.ProviderID {
			result.Reason = "existing_provider_mismatch"
			return result, nil
		}
		switch current.receipt.ASC.Status {
		case "verified":
			if current.receipt.DeveloperPortal.Reason == "developer_team_mismatch" ||
				(current.receipt.DeveloperTeamID != "" && result.DeveloperTeamID != "" &&
					current.receipt.DeveloperTeamID != result.DeveloperTeamID) {
				result.Reason = "existing_developer_team_mismatch"
				return result, nil
			}
			// A partial browser jar cannot replace a complete CLI login. Equal
			// capability also preserves the existing canonical jar byte for byte.
			if current.receipt.DeveloperPortal.Status == "verified" || result.DeveloperPortal.Status != "verified" {
				write = false
				result = current.receipt
				result.Outcome = "existingPreserved"
				result.Reason = "existing_session_at_least_as_capable"
			}
		case "invalid":
			// Only an explicit authentication expiry permits replacing an invalid
			// cache; wrong identity/provider responses are never expiration.
			if current.receipt.ASC.Reason != "session_expired" && current.receipt.ASC.Reason != "no_usable_cookies" {
				result.Reason = "existing_identity_mismatch"
				return result, nil
			}
		default:
			result.Reason = "existing_session_unverified"
			return result, nil
		}
	}
	if ctx.Err() != nil {
		result.Outcome, result.Reason = "rejected", "validation_timeout"
		return result, nil
	}
	err = withBlitzSessionImportLock(selection, key, func() error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		after, err := captureImportedSessionState(selection, key)
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(before, after) {
			return errBlitzSessionChanged
		}
		_, _, selectedKey, selected, err := readLastSessionBySelectionWithOrigin(selection)
		if err != nil {
			return err
		}
		result.SelectionChanged = !selected || selectedKey != key
		if !write {
			if result.SelectionChanged {
				if err := selectBlitzCachedSession(selection, key); err != nil {
					return errors.Join(err, before.restore())
				}
				result.Reason = "existing_session_selected"
			}
			return nil
		}
		// Existing mirrored backends may be independent sessions. Never erase
		// an unvalidated secondary jar while replacing the selected primary.
		if blitzSessionHasDivergentMirror(selection, key, existing, exists) {
			return errBlitzSessionMirrorDiverged
		}
		return persistImportedSessionBySelectionLocked(selection, key, checked.session, exists)
	})
	if err != nil {
		result.Outcome, result.CanonicalChanged, result.SelectionChanged = "rejected", false, false
		switch {
		case errors.Is(err, errBlitzSessionChanged):
			result.Outcome, result.Reason = "conflict", "canonical_session_changed"
		case errors.Is(err, errBlitzSessionMirrorDiverged):
			result.Reason = "cache_backends_diverged"
		default:
			result.Reason = "session_commit_unavailable"
		}
		return result, nil
	}
	if write {
		result.Outcome, result.Reason, result.CanonicalChanged = "imported", "validated_candidate_committed", true
	}
	return result, nil
}

var errBlitzSessionChanged = errors.New("canonical session changed")
var errBlitzSessionMirrorDiverged = errors.New("session cache backends diverged")

// A fresh, explicit browser login also authorizes making that account the CLI
// default. Preserve its already stronger jar and every other account; change
// only the selection in the same CAS transaction. Callers snapshot for rollback.
func selectBlitzCachedSession(selection backendSelection, key string) error {
	if selection.backend == sessionBackendKeychain {
		kr, err := openSessionKeyring()
		if err != nil {
			return err
		}
		store, ok, err := readSessionStoreFromKeyring(kr)
		if err != nil || !ok {
			return errors.New("canonical keychain account unavailable")
		}
		if _, ok := store.Sessions[key]; !ok {
			return errors.New("canonical keychain account unavailable")
		}
		store.LastKey = key
		return writeSessionStoreToKeyring(kr, store)
	}
	path, err := webSessionLastFilePath()
	if err != nil {
		return err
	}
	raw, err := json.Marshal(persistedLastSession{Version: webSessionCacheVersion, Key: key})
	if err != nil {
		return err
	}
	temp, err := createAndWriteSessionTempFile(path, raw)
	if err != nil {
		return err
	}
	defer temp.cleanup()
	return publishSessionTempFile(temp, path)
}

func blitzSessionHasDivergentMirror(selection backendSelection, key string, primary persistedSession, exists bool) bool {
	var mirror persistedSession
	var found bool
	var err error
	if selection.backend == sessionBackendFile && selection.fallbackKeychain {
		mirror, found, err = readSessionFromKeychain(key)
		if isKeyringUnavailable(err) {
			return false
		}
	} else if selection.backend == sessionBackendKeychain && selection.fallbackFile {
		mirror, found, err = readSessionFromFile(key)
	}
	return err != nil || (found && (!exists || !reflect.DeepEqual(mirror, primary)))
}

// Upstream's compatibility lock wrapper is best effort. Import must instead
// fail closed if any of its canonical lock anchors cannot be acquired. Keep the
// same order as CLI persistence and hold locks only for snapshots/commit.
func withBlitzSessionImportLock(selection backendSelection, key string, fn func() error) error {
	releaseGlobal, ok := acquireRequiredSessionCacheGlobalLock()
	if !ok || releaseGlobal == nil {
		return errSessionStoreLockUnavailable
	}
	defer releaseGlobal()
	paths := sessionEntryLockPaths(key)
	if len(paths) == 0 {
		return errSessionStoreLockUnavailable
	}
	var releases []func()
	defer func() {
		for i := len(releases) - 1; i >= 0; i-- {
			releases[i]()
		}
	}()
	for _, path := range paths {
		acquire := acquireLockFile
		if path == sessionSharedEntryLockPath(key) {
			acquire = acquireSharedSessionLockFile
		}
		release, ok := acquire(path)
		if !ok || release == nil {
			return errSessionStoreLockUnavailable
		}
		releases = append(releases, release)
	}
	if selection.backend == sessionBackendKeychain || selection.fallbackKeychain {
		return withSessionStoreLock(fn)
	}
	return fn()
}

func validateBlitzSession(ctx context.Context, source persistedSession, expectedProviderID, expectedTeamID string) blitzSessionAssessment {
	unknown := BlitzSessionEvidence{"unverified", "not_checked"}
	out := blitzSessionAssessment{receipt: BlitzSessionImportResult{ASC: unknown, DeveloperPortal: unknown}}
	jar, err := cookiejar.New(nil)
	if err != nil {
		return out
	}
	if hydrateCookieJar(jar, source) == 0 {
		out.receipt.ASC = BlitzSessionEvidence{"invalid", "no_usable_cookies"}
		return out
	}
	tracker := newSessionCookieTrackingJarWithCached(jar, &source)
	importJar := newBlitzImportCookieJar(tracker, source)
	client := newWebHTTPClient(importJar)
	info, err := sessionInfoFetcher(ctx, client)
	if err != nil {
		out.receipt.ASC = BlitzSessionEvidence{"unverified", "asc_validation_unavailable"}
		if isSessionInfoAuthExpired(err) {
			out.receipt.ASC = BlitzSessionEvidence{"invalid", "session_expired"}
		}
		return out
	}
	if info == nil || strings.TrimSpace(info.User.EmailAddress) == "" ||
		!strings.EqualFold(strings.TrimSpace(source.UserEmail), strings.TrimSpace(info.User.EmailAddress)) {
		out.receipt.ASC = BlitzSessionEvidence{"invalid", "apple_account_mismatch"}
		return out
	}
	if info.Provider.ProviderID <= 0 || info.Provider.PublicProviderID != expectedProviderID ||
		(source.ProviderID != 0 && source.ProviderID != info.Provider.ProviderID) {
		out.receipt.ASC = BlitzSessionEvidence{"invalid", "provider_mismatch"}
		return out
	}
	session := &AuthSession{Client: client}
	applySessionInfo(session, info)
	out.receipt.ASC = BlitzSessionEvidence{"verified", "exact_account_and_provider_verified"}
	out.receipt.AppleID, out.receipt.ProviderID = session.UserEmail, session.PublicProviderID
	portalErr := NewClient(session).BindBlitzReleaseDeveloperTeam(ctx)
	if portalErr == nil {
		if (expectedTeamID != "" && session.DeveloperTeamID != expectedTeamID) ||
			(source.DeveloperTeamID != "" && source.DeveloperTeamID != session.DeveloperTeamID) {
			out.receipt.DeveloperPortal = BlitzSessionEvidence{"invalid", "developer_team_mismatch"}
			return out
		}
		out.receipt.DeveloperPortal = BlitzSessionEvidence{"verified", "exact_provider_team_verified"}
		out.receipt.DeveloperTeamID = session.DeveloperTeamID
	} else {
		out.receipt.DeveloperPortal = BlitzSessionEvidence{"unverified", "developer_portal_unavailable"}
		var denied *developerPortalSessionStatusError
		if errors.As(portalErr, &denied) && (denied.status == http.StatusUnauthorized || denied.status == http.StatusForbidden) {
			out.receipt.DeveloperPortal = BlitzSessionEvidence{"invalid", "developer_portal_auth_required"}
		}
	}
	// Serialize this isolated jar only. Preserve original path/expiry metadata
	// and cookies updated by the validation response, never another session.
	serialized, err := importJar.serialize(session.UserEmail)
	if err != nil {
		out.receipt.ASC = BlitzSessionEvidence{"unverified", "candidate_serialization_failed"}
		return out
	}
	persistableJar, _ := cookiejar.New(nil)
	hydrateCookieJar(persistableJar, serialized)
	olympus, _ := url.Parse(olympusSessionURL)
	if !blitzSameCookieValues(importJar.Cookies(olympus), persistableJar.Cookies(olympus)) {
		out.receipt.ASC = BlitzSessionEvidence{"unverified", "candidate_serialization_failed"}
		return out
	}
	portalURL, _ := url.Parse("https://developer.apple.com" + developerPortalTeamsPath)
	if out.receipt.DeveloperPortal.Status == "verified" &&
		!blitzSameCookieValues(importJar.Cookies(portalURL), persistableJar.Cookies(portalURL)) {
		out.receipt.DeveloperPortal = BlitzSessionEvidence{"unverified", "developer_portal_cookies_not_persistable"}
		out.receipt.DeveloperTeamID = ""
		session.DeveloperTeamID = ""
	}
	serialized.ProviderID = session.ProviderID
	serialized.DeveloperTeamID = session.DeveloperTeamID
	out.session = serialized
	for _, cookies := range serialized.Cookies {
		out.receipt.CookieCount += len(cookies)
	}
	return out
}

func blitzSameCookieValues(a, b []*http.Cookie) bool {
	values := func(cookies []*http.Cookie) map[string]int {
		out := map[string]int{}
		for _, cookie := range cookies {
			cookie = appleCookieForRequest(cookie)
			out[cookie.Name+"\x00"+cookie.Value]++
		}
		return out
	}
	return reflect.DeepEqual(values(a), values(b))
}
