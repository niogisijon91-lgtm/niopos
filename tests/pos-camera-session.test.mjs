import assert from 'node:assert/strict';
import test from 'node:test';

const { createPOSCameraSession, getCameraPrerequisiteError } = await import('../lib/pos-camera-session.ts');

test('reports insecure contexts before unavailable media APIs', () => {
  assert.equal(getCameraPrerequisiteError(false, false), 'secure-context');
  assert.equal(getCameraPrerequisiteError(true, false), 'unavailable');
  assert.equal(getCameraPrerequisiteError(true, true), null);
});

function createCamera() {
  const calls = [];
  const video = { srcObject: { active: true } };
  const controls = { stop: () => calls.push('stop') };
  let onResult;
  const decode = (constraints, targetVideo, callback) => {
    calls.push({ constraints, targetVideo });
    onResult = callback;
    return Promise.resolve(controls);
  };
  return { calls, video, controls, decode, scan: (text) => onResult({ getText: () => text }) };
}

test('uses the requested camera and stops immediately after a barcode is detected', async () => {
  const camera = createCamera();
  const detected = [];
  const session = createPOSCameraSession(camera.decode, camera.video, 'environment', (barcode) => detected.push(barcode));

  await session.started;
  assert.deepEqual(camera.calls[0].constraints.video.facingMode, { ideal: 'environment' });
  camera.scan(' 012345 ');
  camera.scan('012345');

  assert.deepEqual(detected, ['012345']);
  assert.deepEqual(camera.calls.filter((call) => call === 'stop'), ['stop']);
  assert.equal(camera.video.srcObject, null);
});

test('stops the prior camera when closing or switching camera direction', async () => {
  const rearCamera = createCamera();
  const rearSession = createPOSCameraSession(rearCamera.decode, rearCamera.video, 'environment', () => {});
  await rearSession.started;
  rearSession.stop();
  assert.deepEqual(rearCamera.calls.filter((call) => call === 'stop'), ['stop']);

  const frontCamera = createCamera();
  const frontSession = createPOSCameraSession(frontCamera.decode, frontCamera.video, 'user', () => {});
  await frontSession.started;
  assert.deepEqual(frontCamera.calls[0].constraints.video.facingMode, { ideal: 'user' });
  frontSession.stop();
  assert.deepEqual(frontCamera.calls.filter((call) => call === 'stop'), ['stop']);
});

test('stops a camera whose startup resolves after the dialog has closed', async () => {
  let resolveStartup;
  const calls = [];
  const video = { srcObject: { active: true } };
  const session = createPOSCameraSession(
    () => new Promise((resolve) => { resolveStartup = resolve; }),
    video,
    'environment',
    () => {}
  );
  session.stop();

  const controls = { stop: () => calls.push('stop') };
  resolveStartup(controls);
  await session.started;

  assert.deepEqual(calls, ['stop']);
  assert.equal(video.srcObject, null);
});
