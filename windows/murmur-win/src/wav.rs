//! WAV loading and resampling to 16 kHz mono f32.

pub const RATE: u32 = 16_000;

/// Converts mono samples at `rate` to 16 kHz (box filter when downsampling, linear interpolation otherwise).
pub fn resample_16k(x: &[f32], rate: u32) -> Vec<f32> {
    if rate == RATE || x.is_empty() {
        return x.to_vec();
    }
    let ratio = rate as f64 / RATE as f64;
    let n = (x.len() as f64 / ratio).floor() as usize;
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let t = i as f64 * ratio;
        if ratio > 1.0 {
            let a = (t - ratio / 2.0).max(0.0) as usize;
            let b = ((t + ratio / 2.0).ceil() as usize).min(x.len()).max(a + 1);
            out.push(x[a..b].iter().sum::<f32>() / (b - a) as f32);
        } else {
            let i0 = t.floor() as usize;
            let i1 = (i0 + 1).min(x.len() - 1);
            let f = (t - i0 as f64) as f32;
            out.push(x[i0] * (1.0 - f) + x[i1] * f);
        }
    }
    out
}

pub fn load_16k(path: &std::path::Path) -> Result<Vec<f32>, String> {
    let mut r = hound::WavReader::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let spec = r.spec();
    let ch = spec.channels.max(1) as usize;
    let all: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => r.samples::<f32>().filter_map(|s| s.ok()).collect(),
        hound::SampleFormat::Int => {
            let scale = (1u64 << (spec.bits_per_sample - 1)) as f32;
            r.samples::<i32>().filter_map(|s| s.ok()).map(|v| v as f32 / scale).collect()
        }
    };
    let mono: Vec<f32> = all.chunks(ch).map(|f| f.iter().sum::<f32>() / ch as f32).collect();
    Ok(resample_16k(&mono, spec.sample_rate))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resample_lengths() {
        let x = vec![0.5f32; 48_000];
        let y = resample_16k(&x, 48_000);
        assert_eq!(y.len(), 16_000);
        assert!((y[100] - 0.5).abs() < 1e-6);
        let z = resample_16k(&vec![0.1f32; 8000], 8000);
        assert_eq!(z.len(), 8000);
        let up = resample_16k(&vec![0.1f32; 8000], 8000 + 1);
        assert!(!up.is_empty());
    }
}
