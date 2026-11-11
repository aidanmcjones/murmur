//! Microphone capture via cpal/WASAPI -> 16 kHz mono f32. `--test-audio <wav>` feeds a file instead.

use crate::util::log;
use crate::wav;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::FromSample;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};

/// Smoothed input level (f32 bits) for the overlay meter.
pub static LEVEL: AtomicU32 = AtomicU32::new(0);

enum Cmd {
    Start(Sender<Result<(), String>>),
    Stop(Sender<(Vec<f32>, u32)>),
}

pub struct Recorder {
    tx: Mutex<Sender<Cmd>>,
    test: Option<Vec<f32>>,
}

fn build<T>(dev: &cpal::Device, cfg: &cpal::StreamConfig, buf: Arc<Mutex<Vec<f32>>>) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    T: cpal::SizedSample,
    f32: FromSample<T>,
{
    let ch = cfg.channels.max(1) as usize;
    dev.build_input_stream(
        cfg,
        move |data: &[T], _| {
            let mut b = match buf.lock() {
                Ok(b) => b,
                Err(e) => e.into_inner(),
            };
            let mut peak = 0f32;
            for frame in data.chunks(ch) {
                let mut acc = 0f32;
                for s in frame {
                    acc += f32::from_sample(*s);
                }
                let v = acc / ch as f32;
                peak = peak.max(v.abs());
                b.push(v);
            }
            let old = f32::from_bits(LEVEL.load(Ordering::Relaxed));
            LEVEL.store((old * 0.6 + peak * 0.4).to_bits(), Ordering::Relaxed);
        },
        |e| log(&format!("audio: stream error: {e}")),
        None,
    )
}

fn open(buf: Arc<Mutex<Vec<f32>>>) -> Result<(cpal::Stream, u32), String> {
    let host = cpal::default_host();
    let dev = host.default_input_device().ok_or_else(|| "No microphone found".to_string())?;
    let cfg = dev.default_input_config().map_err(|e| format!("Microphone unavailable: {e}"))?;
    let rate = cfg.sample_rate().0;
    let sc: cpal::StreamConfig = cfg.clone().into();
    let stream = match cfg.sample_format() {
        cpal::SampleFormat::F32 => build::<f32>(&dev, &sc, buf),
        cpal::SampleFormat::I16 => build::<i16>(&dev, &sc, buf),
        cpal::SampleFormat::U16 => build::<u16>(&dev, &sc, buf),
        cpal::SampleFormat::I32 => build::<i32>(&dev, &sc, buf),
        f => return Err(format!("unsupported microphone sample format {f:?}")),
    }
    .map_err(|e| format!("Cannot open microphone: {e}"))?;
    stream.play().map_err(|e| format!("Cannot start microphone: {e}"))?;
    log(&format!("audio: recording from '{}' at {rate} Hz, {} ch", dev.name().unwrap_or_default(), sc.channels));
    Ok((stream, rate))
}

impl Recorder {
    pub fn new(test_wav: Option<&std::path::Path>) -> Result<Recorder, String> {
        let test = match test_wav {
            Some(p) => Some(wav::load_16k(p)?),
            None => None,
        };
        let (tx, rx) = channel::<Cmd>();
        // cpal streams are not Send on every backend: keep the stream on its own thread.
        std::thread::spawn(move || {
            let mut active: Option<(cpal::Stream, u32, Arc<Mutex<Vec<f32>>>)> = None;
            while let Ok(c) = rx.recv() {
                match c {
                    Cmd::Start(reply) => {
                        active = None;
                        let buf = Arc::new(Mutex::new(Vec::with_capacity(48_000 * 10)));
                        match open(buf.clone()) {
                            Ok((s, rate)) => {
                                active = Some((s, rate, buf));
                                let _ = reply.send(Ok(()));
                            }
                            Err(e) => {
                                let _ = reply.send(Err(e));
                            }
                        }
                    }
                    Cmd::Stop(reply) => {
                        let out = match active.take() {
                            Some((stream, rate, buf)) => {
                                drop(stream);
                                let v = std::mem::take(&mut *buf.lock().unwrap());
                                (v, rate)
                            }
                            None => (vec![], 16_000),
                        };
                        LEVEL.store(0, Ordering::Relaxed);
                        let _ = reply.send(out);
                    }
                }
            }
        });
        Ok(Recorder { tx: Mutex::new(tx), test })
    }

    pub fn start(&self) -> Result<(), String> {
        if self.test.is_some() {
            return Ok(());
        }
        let (rtx, rrx) = channel();
        self.tx.lock().unwrap().send(Cmd::Start(rtx)).map_err(|_| "audio thread gone".to_string())?;
        rrx.recv().map_err(|_| "audio thread gone".to_string())?
    }

    /// Stops and returns the recording as 16 kHz mono samples.
    pub fn stop(&self) -> Vec<f32> {
        if let Some(t) = &self.test {
            return t.clone();
        }
        let (rtx, rrx) = channel();
        if self.tx.lock().unwrap().send(Cmd::Stop(rtx)).is_err() {
            return vec![];
        }
        match rrx.recv() {
            Ok((v, rate)) => wav::resample_16k(&v, rate),
            Err(_) => vec![],
        }
    }
}
