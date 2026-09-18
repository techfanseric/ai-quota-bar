# Release history

`releases.json` stores the complete original bodies of all published, non-prerelease GitHub Releases. Refresh before each website deployment after publishing a release:

```sh
npm run sync:releases
npm run build:pages
```

The sync script uses the authenticated GitHub CLI, paginates all results, and refuses an empty response. The changelog is rendered at build time, remains readable without JavaScript, and makes no GitHub requests from visitors' browsers. Search only filters the local HTML. Raw HTML and non-HTTP links in release Markdown are not executed.
