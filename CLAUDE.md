## git commit

When creating commits, the `Co-Authored-By:` line must reflect the model actually in use, not a hardcoded default.

### Detecting the active model

1. Check the `ANTHROPIC_MODEL` env var:
   ```bash
   echo "${ANTHROPIC_MODEL:-<not set>}"
   ```
2. If set (e.g. `deepseek-v4-pro`), derive the Co-Authored-By from it:
   - `deepseek-v4-pro` → `Co-Authored-By: DeepSeek V4 Pro <noreply@deepseek.com>`
   - `deepseek-v4-flash` → `Co-Authored-By: DeepSeek V4 Flash <noreply@deepseek.com>`
3. If `ANTHROPIC_MODEL` is not set, the default Anthropic model is in use. Check the system prompt or model metadata for the exact model name (Opus 4.7, Sonnet 4.6, Haiku 4.5, etc.) and use:
   - `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`
   - `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
   - `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`

Never assume "Claude Opus 4.7" — always check which model is actually running.

## Web Search Fallback

WebSearch may fail with non-Anthropic models (400 error, incompatible API). When WebSearch is unavailable, use the following DuckDuckGo HTML fallback.

### Fallback procedure

1. URL-encode the search keywords and fetch DuckDuckGo's HTML search:
   ```
   https://html.duckduckgo.com/html/?q=<URL-encoded-keywords>
   ```
   Use WebFetch to retrieve this URL.

2. Extract relevant result URLs from the returned HTML (look for `result__a` / `result__url` classes in the markup).

3. WebFetch the individual pages that are most relevant to the query.

4. Cite sources as DuckDuckGo result links, not as direct WebSearch citations.

### Encoding example

```bash
# Build the search URL
query="your search keywords"
encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")
url="https://html.duckduckgo.com/html/?q=$encoded"
```
