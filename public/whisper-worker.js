// whisper-worker.js — on-device Whisper (MIT weights, zero cost, audio never leaves the machine)
//
// Runs openai/whisper via Transformers.js (ONNX Runtime Web). WebGPU when the browser
// exposes it, WASM otherwise. The model is downloaded once and then served from the
// browser's cache, so only the first transcription pays the download.
//
// Protocol
//   in : {type:'run', id, audio:Float32Array(16kHz mono), model, language}
//   out: {type:'progress', phase:'download'|'load'|'transcribe', pct, file}
//        {type:'done', id, text, chunks, device, model}
//        {type:'error', id, message}

import { pipeline, env } from 'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.5.1';

env.allowLocalModels = false;

const post = m => self.postMessage(m);

let PIPE = null, PIPE_KEY = '', DEVICE = '';

async function getPipe(model) {
  const wantGpu = !!navigator.gpu;
  const device = wantGpu ? 'webgpu' : 'wasm';
  const key = model + '|' + device;
  if (PIPE && PIPE_KEY === key) return PIPE;

  PIPE = null; PIPE_KEY = '';
  const opts = {
    progress_callback: p => {
      if (p.status === 'progress' && p.total) {
        post({ type: 'progress', phase: 'download', pct: Math.round((p.loaded / p.total) * 100), file: p.file });
      } else if (p.status === 'initiate') {
        post({ type: 'progress', phase: 'download', pct: 0, file: p.file });
      }
    },
  };
  if (device === 'webgpu') {
    opts.device = 'webgpu';
    opts.dtype = { encoder_model: 'fp32', decoder_model_merged: 'q4' };
  } else {
    opts.device = 'wasm';
    opts.dtype = 'q8';
  }

  post({ type: 'progress', phase: 'load', pct: 0 });
  try {
    PIPE = await pipeline('automatic-speech-recognition', model, opts);
    DEVICE = device;
  } catch (e) {
    // WebGPU can fail on some drivers — fall back to WASM rather than giving up
    if (device === 'webgpu') {
      post({ type: 'progress', phase: 'load', pct: 0, file: 'retrying on wasm' });
      PIPE = await pipeline('automatic-speech-recognition', model, {
        progress_callback: opts.progress_callback, device: 'wasm', dtype: 'q8',
      });
      DEVICE = 'wasm';
    } else throw e;
  }
  PIPE_KEY = model + '|' + DEVICE;
  return PIPE;
}

self.onmessage = async e => {
  const msg = e.data || {};
  if (msg.type !== 'run') return;
  const { id, audio, model, language } = msg;
  try {
    const p = await getPipe(model || 'Xenova/whisper-base');

    // coarse progress: Whisper works a 30s window with 5s stride, so ~25s of audio per chunk
    const total = Math.max(1, Math.ceil((audio.length / 16000) / 25));
    let done = 0;
    post({ type: 'progress', phase: 'transcribe', pct: 0 });

    const out = await p(audio, {
      chunk_length_s: 30,
      stride_length_s: 5,
      task: 'transcribe',
      language: language || null,
      return_timestamps: true,
      chunk_callback: () => {
        done += 1;
        post({ type: 'progress', phase: 'transcribe', pct: Math.min(99, Math.round((done / total) * 100)) });
      },
    });

    post({
      type: 'done', id,
      text: (out && out.text ? String(out.text) : '').trim(),
      chunks: (out && Array.isArray(out.chunks))
        ? out.chunks.map(c => ({ start: c.timestamp && c.timestamp[0], end: c.timestamp && c.timestamp[1], text: c.text }))
        : null,
      device: DEVICE, model: model,
    });
  } catch (err) {
    post({ type: 'error', id, message: String((err && err.message) || err) });
  }
};
