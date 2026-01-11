use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub window: WindowConfig,
    pub playback: PlaybackSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowConfig {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackSettings {
    pub wpm: u32,
    #[serde(default = "default_inter_word_delay")]
    pub inter_word_delay_ms: u32,
}

fn default_inter_word_delay() -> u32 {
    10
}

impl Default for Config {
    fn default() -> Self {
        Self {
            window: WindowConfig {
                width: 1800,
                height: 1100,
            },
            playback: PlaybackSettings {
                wpm: 400,
                inter_word_delay_ms: 10,
            },
        }
    }
}

impl Config {
    pub fn config_path() -> Option<PathBuf> {
        dirs::config_dir().map(|p| p.join("SpeedReader").join("config.toml"))
    }

    pub fn load() -> Self {
        Self::config_path()
            .and_then(|path| fs::read_to_string(&path).ok())
            .and_then(|content| toml::from_str(&content).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> bool {
        let Some(path) = Self::config_path() else {
            return false;
        };

        if let Some(parent) = path.parent() {
            if fs::create_dir_all(parent).is_err() {
                return false;
            }
        }

        match toml::to_string_pretty(self) {
            Ok(content) => fs::write(&path, content).is_ok(),
            Err(_) => false,
        }
    }
}
