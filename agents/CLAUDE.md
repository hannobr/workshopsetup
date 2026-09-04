# Workshop project

For ANY browser use — testing, exploration, debugging, scraping, taking
screenshots, anything that drives a browser — use the `playwright-cli`
skill. Do not reach for other browser-automation tools or hand-rolled
scripts.

Use the `playwright-cli` skill to write and run end-to-end tests against
your running application before reporting any change complete. Start the
app, exercise the change through the browser, and verify the full
request/response/render path — regardless of which backend or frontend
stack you've chosen.

Default to launching the browser with `--headed` so attendees can see
what's happening. The user may request headless, or you can ask whether
they want headed or headless if it's unclear.

Serve the app over HTTP, even for a single static page —
`python3 -m http.server` in the project directory is enough. Never open
a page as a `file://` URL: Playwright and web font loading both misbehave
under it, and the breakage looks like a bug in the code rather than a bug
in how the page was opened. Start the server once, at the beginning, and
tell the user the URL.
