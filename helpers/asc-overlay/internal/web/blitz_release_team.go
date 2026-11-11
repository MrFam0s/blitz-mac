package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/readonly"
)

// BindBlitzReleaseDeveloperTeam requires an exact provider/team association.
// Unlike interactive upstream discovery, an unattended release cannot use the
// only available Portal team or a name prefix when the selected ASC provider is
// different. The selected team is then explicitly revalidated by upstream on
// agreement-history and notification reads.
func (c *Client) BindBlitzReleaseDeveloperTeam(ctx context.Context) error {
	headers := developerPortalHeaders("")
	headers.Set("Accept", "application/json, text/javascript, */*; q=0.01")
	headers.Set("Content-Type", "application/x-www-form-urlencoded")
	body, response, err := c.doDeveloperPortalHTTP(readonly.WithReadIntent(ctx), http.MethodPost,
		c.developerPortalOrigin()+developerPortalTeamsPath, nil, headers)
	if err != nil {
		return err
	}
	c.captureDeveloperCSRFTokens(response.Header)
	if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
		return developerPortalSessionError(response, body)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return &APIError{Status: response.StatusCode}
	}
	origin, err := url.Parse(c.developerPortalOrigin())
	if err != nil || (response.Request != nil && response.Request.URL != nil && !sameURLOrigin(origin, response.Request.URL)) {
		return errors.New("developer portal session redirected away from expected origin")
	}
	var payload struct {
		developerPortalTeamsResponse
		ResultCode *int `json:"resultCode"`
	}
	if json.Unmarshal(body, &payload) != nil || (payload.ResultCode != nil && *payload.ResultCode != 0) {
		return errors.New("developer portal teams response unavailable")
	}
	teams := payload.Teams
	if len(teams) == 0 {
		teams = payload.Data.Teams
	}
	selected, err := resolveBlitzReleaseDeveloperTeam(teams, c.publicProviderID, c.providerName)
	if err != nil {
		return err
	}
	c.SetDeveloperTeamSelector(selected.TeamID)
	c.rememberDeveloperPortalTeam(selected.TeamID)
	return nil
}

func resolveBlitzReleaseDeveloperTeam(teams []developerPortalTeam, providerID, providerName string) (developerPortalTeam, error) {
	providerID = strings.TrimSpace(providerID)
	providerName = strings.TrimSpace(providerName)
	var byID, byName []developerPortalTeam
	for _, team := range teams {
		team.TeamID = strings.TrimSpace(team.TeamID)
		team.Name = strings.TrimSpace(team.Name)
		if team.TeamID == "" {
			continue
		}
		if providerID != "" && strings.EqualFold(team.TeamID, providerID) {
			byID = append(byID, team)
		}
		if providerName != "" && strings.EqualFold(team.Name, providerName) {
			byName = append(byName, team)
		}
	}
	if len(byID) == 1 {
		return byID[0], nil
	}
	if len(byID) == 0 && len(byName) == 1 {
		return byName[0], nil
	}
	return developerPortalTeam{}, errors.New("developer portal team has no unique exact binding to selected provider")
}
