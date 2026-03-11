/**
 * Build script: creates a zip file suitable for Chrome Web Store submission.
 * Run with: npm run build
 */
const fs = require('fs')
const path = require('path')
const archiver = require('archiver')

const ROOT = path.join(__dirname, '..')
const DIST = path.join(ROOT, 'dist')

if (!fs.existsSync(DIST)) {
  fs.mkdirSync(DIST)
}

const outputPath = path.join(DIST, 'jira-enhancer.zip')
const output = fs.createWriteStream(outputPath)
const archive = archiver('zip', { zlib: { level: 9 } })

output.on('close', () => {
  console.log(`Build complete: ${outputPath} (${archive.pointer()} bytes)`)
})

archive.on('error', (err) => {
  throw err
})

archive.pipe(output)

// Files to include in the extension package
const filesToInclude = [
  'manifest.json',
  'background.js',
  'content.js',
  'floating-header.js',
  'inline-copy.js',
  'search-modal.js',
  'options.html',
  'options.js',
  'styles.css'
]

const dirsToInclude = [
  'lib',
  'icons'
]

filesToInclude.forEach((file) => {
  const filePath = path.join(ROOT, file)
  if (fs.existsSync(filePath)) {
    archive.file(filePath, { name: file })
  } else {
    console.warn(`Warning: ${file} not found, skipping`)
  }
})

dirsToInclude.forEach((dir) => {
  const dirPath = path.join(ROOT, dir)
  if (fs.existsSync(dirPath)) {
    archive.directory(dirPath, dir)
  } else {
    console.warn(`Warning: ${dir}/ not found, skipping`)
  }
})

archive.finalize()
