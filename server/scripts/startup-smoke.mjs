import { spawn } from 'node:child_process';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';

assert(process.env.TEST_DATABASE_URL, 'Requires the disposable test database');
const child = spawn(process.execPath, ['dist/server.js'], {
  env: {
    ...process.env,
    NODE_ENV: 'test',
    DATABASE_URL: process.env.TEST_DATABASE_URL,
    HOST: '127.0.0.1',
    PORT: '18765',
    FIREBASE_PROJECT_ID: '',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let output = '';
child.stdout.on('data', chunk => { output += chunk; });
child.stderr.on('data', chunk => { output += chunk; });
const exited = once(child, 'exit');
try {
  let healthy = false;
  for (let attempt = 0; attempt < 80; attempt++) {
    assert.equal(child.exitCode, null, output);
    try {
      const response = await fetch('http://127.0.0.1:18765/health');
      healthy = response.ok;
    } catch {}
    if (healthy) break;
    await delay(100);
  }
  assert(healthy, output || 'Server did not become healthy');
  await delay(250);
  assert.equal(child.exitCode, null, output);
  child.kill('SIGTERM');
  const result = await Promise.race([exited, delay(5000).then(() => null)]);
  assert(result, 'Server did not shut down');
  assert.equal(result[0], 0, output);
  console.log('Server startup, health, and graceful shutdown passed');
} finally {
  if (child.exitCode === null) child.kill('SIGKILL');
}
