# Configuring public OIDC discovery with Cloudflare Pages

Prerequisites: `.env` has `OIDC_HOST` and `CLOUDFLARE_PAGES_PROJECT` set, and `scripts/createcluster.sh` has already run (the publish script reads the OIDC documents from the cluster with `kubectl`).

- Go to the Build / Compute → Workers & Pages tab.
- Select "legacy" and continue to the Pages link.
- Select "Get started" for the drag and drop option.
- Name your project as `CLOUDFLARE_PAGES_PROJECT`, e.g. `kind-oidc`.
- Click Create project.
- Take note of the page name (e.g. `kind-oidc.pages.dev`).
- Add a dummy `index.html` page.
- Click `Deploy`.
- Check the production branch is `main` (project Settings → Builds). The publish script deploys with `--branch main`; any other branch is a preview deployment and the custom domain will not serve it.
- Click the `Custom domains` tab at the top of the page and add your `$OIDC_HOST` domain name. This creates a CNAME record and maps it to the Pages project.
- **It will take a few minutes to propagate.**
- Test your dummy index page is rendering by hitting `https://$OIDC_HOST` in an incognito browser.
- Run `scripts/cloudflarepublish.sh` to upload the OIDC files. It runs `wrangler login` itself if you are not logged in. Alternatively, set `CLOUDFLARE_API_TOKEN` (scoped to read/write Pages) and `CLOUDFLARE_ACCOUNT_ID` first.
- Check your OIDC discovery document: `https://$OIDC_HOST/.well-known/openid-configuration`
- Check your OIDC public keys: `https://$OIDC_HOST/openid/v1/jwks`

Shortcut: instead of the dashboard steps for creating the project, run `wrangler pages project create <name> --production-branch main`. You still need to add the custom domain in the dashboard.
