---
name: asc-iap-attach
description: Select exact In-App Purchase, subscription and subscription-group metadata versions for a joint app submission through Blitz Neo. Use when products must accompany an app release; product creation and metadata editing remain separate preparation steps.
---

# Include purchases and subscriptions in a Blitz release

Use the `blitz-release` skill for the enclosing app release. This skill defines
its explicit product selection, not a second submission path. Preparing or listing
products does not authorize their publication. Preserve the user's authorized
app, platform, products, release mode and existing operation.

Apple's first product of each purchase type must accompany an app version. A new
subscription also needs its group in the same submission if that group has not
been approved; each new group needs a selected subscription. Blitz uses the public
version-based review API for that single draft. It does not read browser cookies
or set the old `submitWithNextAppStoreVersion` flag.

## Identify the exact metadata versions

Read the installed ASC command help and the project's product facts. List products
for the intended app and resolve only the authorized products, using their stable
product ID/name and app relationship. Then list their metadata versions with the
read-only commands supported by the bundled ASC:

```bash
asc iap versions list --iap-id "PARENT_IAP_ID" --paginate
asc subscriptions versions list --subscription-id "PARENT_SUBSCRIPTION_ID" --paginate
asc subscriptions groups versions list --group-id "PARENT_GROUP_ID" --paginate
```

Use the returned **version resource ID** and type, never a parent product ID,
product identifier string, guessed newest item or a version from another app.
Check version state, localizations and images, the product's review screenshot,
pricing/availability and required group membership. Complete missing metadata
within the user's scope through the documented ASC preparation commands before
preparing the release. Read each command's help rather than inventing options.
Unrelated ready products are not automatically included. If the requested product
scope cannot be established, clarify that selection only.

## Bind the set to the app release

Add the selected versions to the ordinary `release prepare` request:

```json
"reviewItems": [
  {"type": "inAppPurchaseVersions", "id": "IAP_VERSION_ID"},
  {"type": "subscriptionGroupVersions", "id": "GROUP_VERSION_ID"},
  {"type": "subscriptionVersions", "id": "SUBSCRIPTION_VERSION_ID"}
]
```

This is a fragment of the request, not a complete request file. Keep the exact
project/account/app/platform/version/build/release-mode fields required by
`blitz-release`. Include only the applicable entries, at most 199 unique product
versions alongside the app. An omitted/empty array means app-only. Review the
returned `target.reviewItems` and retain its operation ID and confirmation digest.
The equivalent MCP input is `release_prepare.reviewItems`.

`prepare` and `validate` only read Apple. Blitz verifies ownership, required group
and first-of-type dependencies, selected content and review media. A missing
attachment that this exact plan will create is checked against that selection;
it is not a reason to ignore other validation failures. No raw product metadata
or review credentials are placed in the journal.

For an authorized release, use the same Blitz `submit` operation. It adds the app
and the saved selected versions to one review draft, verifies the complete set,
and sends that draft once. Never pre-attach products through `asc review items add`,
raw review APIs, the former Iris scripts or a separate IAP/subscription submit as
an alternative route around Blitz's journal or checks.

## Interruption and changes

Use `release status` after an interruption. If it returns `resumableSubmissionId`,
continue only that exact owned draft with the original operation, digest and
selection. Continuation can add its missing saved items; it cannot add a different
product or create another draft. An uncertain final submit permits read-only
reconciliation only. A conflict is not success, and a draft is not submitted.

Changes to the selected set, product texts, images or review screenshots require
fresh preparation before any submission has begun. Do not reset an incomplete
operation, edit its journal or create a replacement to bypass uncertainty.
Report the app version/build, each selected resource version and Apple's verified
submission state. Approval of one item does not prove that all items are approved.

Sources: [Apple's submission rules](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase),
[version-based metadata and review API](https://developer.apple.com/documentation/appstoreconnectapi/migrating-in-app-purchase-metadata-to-v2).
