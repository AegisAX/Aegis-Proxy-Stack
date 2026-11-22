'use strict';

// The inputs are the frontend-independent backend files from the pinned NPM 2.12.6 image.
const crypto = require('node:crypto');
const fs = require('node:fs');

const changes = [
  {
    file: '/app/setup.js',
    original: '873fecb8692861c8c78d1dfafc05704344f22b40de1f373e8e6472c779498a4a',
    patched: 'a5d11fcf36d6fd328a68f42128affd4252da2fc91a91d29fb7200d906e5e2a43',
    before: "logger.info('Creating a new user: ' + email + ' with password: ' + password);",
    after: "logger.info('Creating initial administrator');",
  },
  {
    file: '/app/internal/certificate.js',
    original: 'efb5b9243dae80394816e55bfd391051f397b5d579aee48e6b73f5a175994bc3',
    patched: '51a43df733961c6616b547d4a7311f3526ffb6b2419959eb3d63c842ca0d12b6',
    before: "logger.info('Writing Custom Certificate:', certificate);",
    after: "logger.info('Writing custom certificate');",
  },
];

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

const mode = process.argv[2];
if (process.argv.length !== 3 || !['--apply', '--check'].includes(mode)) {
  throw new Error('Usage: node patch-app-logging.js --apply | --check');
}
const outputs = changes.map(({file, original, patched, before, after}) => {
  const source = fs.readFileSync(file, 'utf8');
  if (mode === '--check') {
    if (sha256(source) !== patched || !source.includes(after) || source.includes(before)) {
      throw new Error('Unexpected patched logging source in ' + file);
    }
    return source;
  }
  if (sha256(source) !== original || source.split(before).length !== 2) {
    throw new Error('Unexpected original logging source in ' + file);
  }
  const result = source.replace(before, after);
  if (sha256(result) !== patched) {
    throw new Error('Unexpected logging patch result in ' + file);
  }
  return result;
});

if (mode === '--apply') {
  changes.forEach(({file}, index) => fs.writeFileSync(file, outputs[index]));
}
