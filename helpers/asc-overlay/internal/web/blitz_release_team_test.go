package web

import "testing"

func TestBlitzReleaseTeamNeverUsesUnrelatedSoleTeamOrPrefix(t *testing.T) {
	for _, test := range []struct {
		name, providerID, providerName string
		teams                          []developerPortalTeam
		want                           string
	}{
		{"unrelated sole personal team", "ORGPROVIDER", "Organisation B", []developerPortalTeam{{TeamID: "PERSONALA", Name: "Personal A"}}, ""},
		{"name prefix is insufficient", "ORGPROVIDER", "Organisation B Subsidiary", []developerPortalTeam{{TeamID: "PARENTB", Name: "Organisation B"}}, ""},
		{"public ID matches", "ORGTEAM", "Organisation B", []developerPortalTeam{{TeamID: "ORGTEAM", Name: "B"}, {TeamID: "PERSONALA", Name: "Personal A"}}, "ORGTEAM"},
		{"unique exact provider name bridges different IDs", "PUBLICUUID", "Organisation B", []developerPortalTeam{{TeamID: "DEVTEAM", Name: "Organisation B"}}, "DEVTEAM"},
		{"duplicate name ambiguous", "PUBLICUUID", "Organisation B", []developerPortalTeam{{TeamID: "DEVONE", Name: "Organisation B"}, {TeamID: "DEVTWO", Name: "Organisation B"}}, ""},
		{"missing provider never sole fallback", "", "", []developerPortalTeam{{TeamID: "PERSONALA", Name: "Personal A"}}, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := resolveBlitzReleaseDeveloperTeam(test.teams, test.providerID, test.providerName)
			if test.want == "" {
				if err == nil {
					t.Fatalf("accepted unrelated team %#v", got)
				}
			} else if err != nil || got.TeamID != test.want {
				t.Fatalf("got %#v err %v", got, err)
			}
		})
	}
}
