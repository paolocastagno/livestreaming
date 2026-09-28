/* global shaka */
'use strict';

const video = document.querySelector('#video');
const protocol = document.querySelector('#protocol');
const quality = document.querySelector('#quality');
const state = document.querySelector('#state');
const message = document.querySelector('#message');
let player;
let retryTimer;

const manifests = {
  dash: 'dash/manifest.mpd',
  hls: 'hls/master.m3u8',
};

function formatRate(bits) {
  if (!bits || !Number.isFinite(bits)) return '—';
  return bits >= 1e6 ? `${(bits / 1e6).toFixed(2)} Mb/s` : `${Math.round(bits / 1e3)} kb/s`;
}

function setState(name, text) {
  state.className = `badge ${name}`;
  state.textContent = text;
}

function populateQualities() {
  const selected = quality.value;
  const tracks = player.getVariantTracks()
    .filter((track) => track.height)
    .sort((a, b) => a.height - b.height);
  const unique = [...new Map(tracks.map((track) => [track.height, track])).values()];
  quality.innerHTML = '<option value="auto">Auto (ABR)</option>';
  for (const track of unique) {
    const option = document.createElement('option');
    option.value = String(track.id);
    option.textContent = `${track.height}p · ${formatRate(track.bandwidth)}`;
    quality.append(option);
  }
  if ([...quality.options].some((option) => option.value === selected)) quality.value = selected;
}

async function loadStream(attempt = 0) {
  clearTimeout(retryTimer);
  setState('waiting', 'loading');
  message.textContent = `Loading ${protocol.value.toUpperCase()} live manifest…`;
  try {
    await player.load(manifests[protocol.value]);
    populateQualities();
    quality.value = 'auto';
    player.configure({ abr: { enabled: true } });
    await video.play().catch(() => {});
    setState('live', 'live');
    message.textContent = 'Adaptive playback is active through the CDN and residential access path.';
  } catch (error) {
    const delay = Math.min(2000 + attempt * 1000, 7000);
    setState('waiting', 'retrying');
    message.textContent = `Manifest is not ready (${error.code || error.message}). Retrying…`;
    retryTimer = setTimeout(() => loadStream(attempt + 1), delay);
  }
}

function updateStats() {
  if (!player) return;
  const stats = player.getStats();
  const active = player.getVariantTracks().find((track) => track.active);
  document.querySelector('#resolution').textContent = active?.height ? `${active.width}×${active.height}` : '—';
  document.querySelector('#bitrate').textContent = formatRate(active?.bandwidth);
  document.querySelector('#bandwidth').textContent = formatRate(stats.estimatedBandwidth);

  let ahead = 0;
  for (let i = 0; i < video.buffered.length; i += 1) {
    if (video.buffered.start(i) <= video.currentTime && video.buffered.end(i) >= video.currentTime) {
      ahead = video.buffered.end(i) - video.currentTime;
    }
  }
  document.querySelector('#buffer').textContent = `${ahead.toFixed(1)} s`;

  const range = player.seekRange();
  const latency = range.end > 0 ? Math.max(0, range.end - video.currentTime) : NaN;
  document.querySelector('#latency').textContent = Number.isFinite(latency) ? `${latency.toFixed(1)} s` : '—';
  document.querySelector('#dropped').textContent = String(stats.droppedFrames ?? 0);
}

async function init() {
  shaka.polyfill.installAll();
  if (!shaka.Player.isBrowserSupported()) {
    setState('error', 'unsupported');
    message.textContent = 'This browser does not provide the Media Source APIs required by Shaka Player.';
    return;
  }

  player = new shaka.Player();
  await player.attach(video);
  player.addEventListener('error', (event) => {
    console.error('Shaka error', event.detail);
  });
  player.addEventListener('adaptation', populateQualities);

  protocol.addEventListener('change', () => loadStream());
  document.querySelector('#reload').addEventListener('click', () => loadStream());
  quality.addEventListener('change', () => {
    if (quality.value === 'auto') {
      player.configure({ abr: { enabled: true } });
      return;
    }
    player.configure({ abr: { enabled: false } });
    const track = player.getVariantTracks().find((candidate) => String(candidate.id) === quality.value);
    if (track) player.selectVariantTrack(track, true, 2);
  });

  setInterval(updateStats, 1000);
  await loadStream();
}

document.addEventListener('DOMContentLoaded', init);
