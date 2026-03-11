/**
 * Dev watch script: watches for file changes and logs them.
 * Chrome extensions don't hot-reload automatically, but this notifies
 * you which files changed so you can manually reload the extension.
 *
 * Run with: npm run dev
 */
const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')

const watchPaths = [
  'manifest.json',
  'background.js',
  'content.js',
  'floating-header.js',
  'inline-copy.js',
  'search-modal.js',
  'options.js',
  'options.html',
  'styles.css',
  path.join('lib', 'jira-selectors.js'),
  path.join('lib', 'dom-observer.js'),
  path.join('lib', 'jql-builder.js'),
  path.join('lib', 'cache.js')
]

console.log('[Jira Enhancer Dev] Watching for changes...')
console.log('[Jira Enhancer Dev] After any change, go to chrome://extensions and click the reload button.')
console.log('')

watchPaths.forEach((file) => {
  const fullPath = path.join(ROOT, file)
  if (fs.existsSync(fullPath)) {
    fs.watch(fullPath, (eventType) => {
      if (eventType === 'change') {
        console.log(`[${new Date().toLocaleTimeString()}] Changed: ${file}`)
        console.log('  -> Reload the extension at chrome://extensions')
      }
    })
  }
})
