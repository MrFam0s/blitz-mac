package web

import (
	"errors"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"time"
)

// Upstream tracks path cookies at ASC's Olympus endpoint, but its fixed probe
// list cannot retain Developer Portal /services-account cookies. This local
// importer records only known source scopes and actual Set-Cookie responses;
// it never broadens a path, fabricates an expiry, or combines separate jars.
type blitzImportCookieJar struct {
	base    *sessionCookieTrackingJar
	mu      sync.Mutex
	records map[string]map[string]pCookie
}

func newBlitzImportCookieJar(base *sessionCookieTrackingJar, source persistedSession) *blitzImportCookieJar {
	jar := &blitzImportCookieJar{base: base, records: map[string]map[string]pCookie{}}
	for origin, cookies := range source.Cookies {
		for _, cookie := range cookies {
			jar.remember(origin, cookie)
		}
	}
	return jar
}

func (j *blitzImportCookieJar) remember(origin string, cookie pCookie) {
	if j.records[origin] == nil {
		j.records[origin] = map[string]pCookie{}
	}
	// Host narrowing is the cache's storage identity; the jar observation
	// below rejects records no longer present after renewal/deletion.
	key := strings.Join([]string{cookie.Name, persistedCookiePath(cookie.Path)}, "\x00")
	j.records[origin][key] = cookie
}

func (j *blitzImportCookieJar) Cookies(u *url.URL) []*http.Cookie { return j.base.Cookies(u) }

func (j *blitzImportCookieJar) SetCookies(u *url.URL, cookies []*http.Cookie) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.base.SetCookies(u, cookies)
	if u == nil {
		return
	}
	now := time.Now().UTC()
	for _, supplied := range cookies {
		if supplied == nil || supplied.Name == "" {
			continue
		}
		cookie := pCookie{Name: supplied.Name, Value: supplied.Value, Path: effectiveCookiePath(u, supplied),
			Domain: supplied.Domain, Expires: supplied.Expires, MaxAge: supplied.MaxAge,
			Secure: supplied.Secure, HttpOnly: supplied.HttpOnly, SameSite: int(supplied.SameSite)}
		cookie, _ = normalizePersistedCookieDeadline(cookie, now)
		// Probe the actual response cookie's permitted origin/path, including
		// deletions, without using any token from another cached session.
		probe, _ := cookiejar.New(nil)
		live := *supplied
		live.Value, live.Expires, live.MaxAge = "scope-probe", time.Time{}, 0
		probe.SetCookies(u, []*http.Cookie{&live})
		for _, origin := range sessionCookieURLs() {
			pathProbe := *origin
			pathProbe.Path = cookie.Path
			if cookieListContains(probe.Cookies(&pathProbe), supplied.Name, "scope-probe") {
				record := cookie
				key := strings.Join([]string{cookie.Name, persistedCookiePath(cookie.Path)}, "\x00")
				if previous, found := j.records[origin.String()][key]; found && isSessionOnlyCookie(record) &&
					(previous.MaxAge < 0 || !isSessionOnlyCookie(previous)) {
					// Match upstream's deadline protection: a response that turns
					// a bounded credential into a session-only cookie cannot grant
					// an unlimited persisted lifetime, even when its value matches.
					record.MaxAge = -1
				}
				j.remember(origin.String(), record)
			}
		}
	}
}

func (j *blitzImportCookieJar) serialize(userEmail string) (persistedSession, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	// Reuse upstream's fresh generation/timestamp, but supply all known paths
	// instead of the fixed root-only list. No cache persistence happens here.
	serialized, err := serializeCookieJarWithError(j.base, userEmail)
	if err != nil {
		return persistedSession{}, err
	}
	serialized.Cookies = map[string][]pCookie{}
	for rawOrigin, records := range j.records {
		canonical, allowed := canonicalSessionCookieURL(rawOrigin)
		if !allowed {
			return persistedSession{}, errors.New("unsupported session cookie origin")
		}
		origin, _ := url.Parse(canonical)
		for _, cookie := range records {
			if isExpiredCookie(cookie, serialized.UpdatedAt) || !cookieDomainStorableForOrigin(origin, cookie) {
				continue
			}
			probe := *origin
			probe.Path = persistedCookiePath(cookie.Path)
			observed := j.base.Cookies(&probe)
			if !cookieListContains(observed, cookie.Name, cookie.Value) {
				continue
			}
			if observedCookieNameCount(observed, cookie.Name) > 1 {
				known, actual := map[string]int{}, map[string]int{}
				for _, scoped := range records {
					if scoped.Name == cookie.Name && !isExpiredCookie(scoped, serialized.UpdatedAt) &&
						persistedCookiePathMatches(scoped.Path, probe.Path) {
						known[scoped.Value]++
					}
				}
				for _, value := range observed {
					if value.Name == cookie.Name {
						actual[value.Value]++
					}
				}
				if !reflect.DeepEqual(known, actual) {
					// Known distinct paths are safe. Unexplained domain aliases
					// cannot be represented by the host-narrowed cache.
					return persistedSession{}, errors.New("ambiguous session cookie scope")
				}
			}
			serialized.Cookies[canonical] = append(serialized.Cookies[canonical], cookie)
		}
	}
	narrowPersistedCookieDomains(&serialized)
	check, _ := cookiejar.New(nil)
	hydrateCookieJar(check, serialized)
	olympus, _ := url.Parse(olympusSessionURL)
	if len(check.Cookies(olympus)) == 0 {
		return persistedSession{}, errors.New("validated ASC cookies cannot be persisted")
	}
	return serialized, nil
}
