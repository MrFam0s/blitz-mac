# China mainland release declarations

## Establish what the app offers

1. Bind the Apple app ID and provider to the release target. Read the complete
   territory selection for that app, including the `available` value for `CHN`.
   Hong Kong, Macao and Taiwan are separate storefronts. If the user plans to add
   China, prepare the answers even before selection. Change availability only if
   that change is part of the request.
2. Read Apple's current requirements under General → App Compliance. For the two
   feature questions use `~/.blitz/bin/asc web apps compliance list --app APP_ID
   --public-provider-id PROVIDER_ID`, with the verified IDs. Account Holder or
   Admin access is required to file them. Inspect any other required CHN row in
   Apple's current form. An incomplete, ambiguous or differently scoped response
   leaves its status unknown.
3. Review the shipping features of **all platforms sharing this Apple app ID**,
   including dependencies, hosted content, backend services and live region
   switches. Match release code and configuration to product docs and the actual
   user journey. A supported “No” requires evidence covering those paths or a
   verified restriction for users in mainland China. A missing SDK name, code
   search hit, Store localization or historic answer alone cannot establish this.
4. Record each result, its feature or configuration reference and the checked
   build/date in `docs/blitz-product.md`. Add the section to an existing document
   as needed. Keep contracts, filings and reports in the private release records.
   Recheck saved answers when a model, service, target or regional setting changes.

## Answer the two questions independently

| Apple field | Determine from the CHN user experience | Evidence for a positive answer |
| --- | --- | --- |
| `AI_GENERATED_CONTENT` | Does the app provide generation or synthetic media services, such as a chatbot, image or video creation, or face or voice alteration? Include integrated third-party services. | Use the exact approved filing type (LLM or algorithm), registered name and filing number. For external technology, check the owner's authorization identifies the model and number, the authorized app provider and the owner registered with the CAC. |
| `SECURITY_ASSESSMENT` | Check distribution of generated or synthetic content, end-to-end encrypted instant messaging and other applicable services allowing public expression or mobilization, such as public forums or group broadcasts. Trace what users can send, publish and receive. | Check the national platform screenshot for the app, provider and successful review. Match the completed assessment report to the same app and provider and verify the official company seal. |

Static editorial material, a deterministic coach or ordinary encrypted transport
alone does not establish either feature. Conversely, a regionally enabled hosted
service can make a declaration applicable even if the client contains no model.
Where the features or legal applicability remain uncertain, obtain the specific
missing fact from the provider. Redact confidential information from documents
while retaining the evidence Apple requires. [Apple's current form and evidence requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-china-mainland-compliance-information/) · [CAC scope of security assessments, articles 2–3](https://www.cac.gov.cn/2018-11/15/c_1123716072.htm)

## Check registrations that depend on the app

| When applicable | What to match to the app and provider |
| --- | --- |
| MIIT app ICP filing | Verify the actual app filing number. Match filed metadata against the Simplified Chinese store information, or the primary language if that localization is absent. A website ICP number or missing project document cannot establish the app's filing or exemption. |
| Games | NPPA approval number, the ISBN issuing letter or approval reply and the current business license. Include an operator authorization agreement when applicable. |
| Books or magazines, news, religious content | Check the content actually offered. Match the publishing permit (NPPA), internet news permit (CAC), or religious information permit (NRAA) respectively and the supporting authorization or license that Apple requests. |

Use the current App Compliance form for these registrations. Copy official
identifiers only from a verified Apple record or matching documentary evidence.
If the provider is an organization based in mainland China, its Chinese legal
name and Unified Social Credit Identifier come from the D‑U‑N‑S account details
displayed under Business → Agreements. [Apple's permit reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-and-compliance-information/) · [MIIT filing guidance](https://www.miit.gov.cn/zwgk/zcwj/wjfb/tz/art/2023/art_920db564162e4312916a01bed6540ad8.html) · [Apple's organization details](https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-china-mainland-compliance-information/)

## Apply the answer and verify it

During an authorized CHN release, fill each outstanding declaration the provider's
mandate covers using the verified answer and matching files. Reuse an existing
authorization for that scope. For preparation only, keep the result local.
Collect outstanding facts, missing official records or a missing authority to
file in one targeted question. A gallery update alone grants no filing authority.

For the two feature declarations use `asc web apps compliance set` with the
same `--app` and `--public-provider-id`, the exact `--requirement` and
`--declared true|false`. Supply these additional flags only for a “Yes”:

- AI: `--filing-type LLM|ALGORITHM`, `--filing-name`, `--filing-number`,
  `--third-party-technology true|false` and, when true, `--third-party-authorization`.
- Assessment: `--proof` and `--report` with the two checked documents.

Check the installed command's help. Its `--dry-run` checks the Apple web form
and can transfer attachments. Use it only within the authorized disclosure.
Save with `--confirm`. After each save or uncertain response, reread the
app/provider-bound list before considering another write. Preserve an existing
collected answer consistent with the release. A status alone does not reveal the
saved Yes/No. A pending filing is read-only. If its details cannot be reconciled
with the shipped features, identify the discrepancy and Apple's correction path
before attempting a replacement. Report pending
verification separately from acceptance or rejection and read the territory's
availability before reporting it live. Revalidate the same Blitz release operation.

Apple's transition deadline for existing mainland China listings is **January 31,
2027**. Both declarations must have completed verification by that date to retain
availability there. [Apple's transition rule](https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-china-mainland-compliance-information/)
