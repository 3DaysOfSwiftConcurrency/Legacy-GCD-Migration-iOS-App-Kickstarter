import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const projectRoot = process.cwd();
const forbiddenMarker = /\b(?:CFA_UNIT_TEST_HOST|(?:UI|UNIT|SNAPSHOT)_TEST_HOST)\b/i;
const violations = [];

function files(inDirectory) {
  return readdirSync(inDirectory, { withFileTypes: true }).flatMap(entry => {
    const path = join(inDirectory, entry.name);
    if (entry.isDirectory()) return files(path);
    return [path];
  });
}

function inspect(path) {
  if (!statSync(path).isFile()) return;
  const contents = readFileSync(path, 'utf8');
  if (forbiddenMarker.test(contents)) {
    violations.push(relative(projectRoot, path));
  }
}

for (const path of files(join(projectRoot, 'Kickstarter-iOS'))) {
  if (path.endsWith('.swift')) inspect(path);
}

for (const path of files(join(projectRoot, 'Kickstarter.xcodeproj', 'xcshareddata', 'xcschemes'))) {
  if (path.endsWith('.xcscheme')) inspect(path);
}

inspect(join(projectRoot, 'Kickstarter.xctestplan'));

if (violations.length > 0) {
  throw new Error(
    `Test-host integrity failed. Test-only launch markers are prohibited because tests must not replace the app root or window:\n${violations.join('\n')}`
  );
}

console.log('Test-host integrity check passed.');
