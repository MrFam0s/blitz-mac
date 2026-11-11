package validate

import (
	"context"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/validation"
	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

// BlitzDeepClient keeps all deep checks on the same app/provider-verified web
// session. It intentionally exposes only the three upstream read operations.
type BlitzDeepClient interface {
	GetAppDataUsagesPublishState(context.Context, string) (*webcore.AppDataUsagesPublishState, error)
	ListReviewSubscriptions(context.Context, string) ([]webcore.ReviewSubscription, error)
	GetAgreementsStatus(context.Context) (*asc.WebAgreementsStatusResult, error)
}

func ApplyBlitzDeepValidation(ctx context.Context, report validation.Report, client BlitzDeepClient) validation.Report {
	status := validation.DeepSessionCached
	if client == nil {
		status = validation.DeepSessionUnavailable
	}
	deep, findings := buildDeepValidation(ctx, report, client, status)
	return validation.ApplyDeepValidation(report, deep, findings)
}
