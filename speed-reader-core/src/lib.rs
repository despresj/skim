mod clipboard;
mod tokenizer;

use clipboard::ClipboardManager;
use tokenizer::Tokenizer;

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(swift_repr = "struct")]
    struct WordToken {
        pub text: String,
        pub index: u32,
        pub total: u32,
        pub display_time_ms: u32,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct PlaybackConfig {
        pub wpm: u32,
        pub pause_on_punctuation: bool,
        pub punctuation_multiplier: f32,
    }

    extern "Rust" {
        type SpeedReader;

        #[swift_bridge(init)]
        fn new() -> SpeedReader;

        // Clipboard operations
        fn read_clipboard(&mut self) -> Option<String>;
        fn has_clipboard_text(&mut self) -> bool;

        // Text loading and tokenization
        fn load_text(&mut self, text: String);
        fn get_word_count(&self) -> u32;

        // Playback control
        fn set_config(&mut self, config: PlaybackConfig);
        fn get_current_word(&self) -> Option<WordToken>;
        fn advance(&mut self) -> Option<WordToken>;
        fn go_back(&mut self) -> Option<WordToken>;
        fn seek_to(&mut self, index: u32) -> Option<WordToken>;
        fn reset(&mut self);

        // State queries
        fn is_at_start(&self) -> bool;
        fn is_at_end(&self) -> bool;
        fn get_progress_percent(&self) -> f32;
    }
}

pub struct SpeedReader {
    clipboard: ClipboardManager,
    tokenizer: Tokenizer,
    config: ffi::PlaybackConfig,
    current_index: usize,
}

impl SpeedReader {
    fn new() -> Self {
        Self {
            clipboard: ClipboardManager::new(),
            tokenizer: Tokenizer::new(),
            config: ffi::PlaybackConfig {
                wpm: 300,
                pause_on_punctuation: true,
                punctuation_multiplier: 1.5,
            },
            current_index: 0,
        }
    }

    fn read_clipboard(&mut self) -> Option<String> {
        self.clipboard.get_text()
    }

    fn has_clipboard_text(&mut self) -> bool {
        self.clipboard.has_text()
    }

    fn load_text(&mut self, text: String) {
        self.tokenizer.tokenize(&text);
        self.current_index = 0;
    }

    fn get_word_count(&self) -> u32 {
        self.tokenizer.len() as u32
    }

    fn set_config(&mut self, config: ffi::PlaybackConfig) {
        self.config = config;
    }

    fn get_current_word(&self) -> Option<ffi::WordToken> {
        self.create_word_token(self.current_index)
    }

    fn advance(&mut self) -> Option<ffi::WordToken> {
        if self.current_index + 1 < self.tokenizer.len() {
            self.current_index += 1;
            self.create_word_token(self.current_index)
        } else {
            None
        }
    }

    fn go_back(&mut self) -> Option<ffi::WordToken> {
        if self.current_index > 0 {
            self.current_index -= 1;
            self.create_word_token(self.current_index)
        } else {
            None
        }
    }

    fn seek_to(&mut self, index: u32) -> Option<ffi::WordToken> {
        let idx = index as usize;
        if idx < self.tokenizer.len() {
            self.current_index = idx;
            self.create_word_token(self.current_index)
        } else {
            None
        }
    }

    fn reset(&mut self) {
        self.current_index = 0;
    }

    fn is_at_start(&self) -> bool {
        self.current_index == 0
    }

    fn is_at_end(&self) -> bool {
        self.tokenizer.is_empty() || self.current_index >= self.tokenizer.len() - 1
    }

    fn get_progress_percent(&self) -> f32 {
        if self.tokenizer.is_empty() {
            0.0
        } else {
            (self.current_index as f32) / (self.tokenizer.len() as f32 - 1.0).max(1.0)
        }
    }

    fn create_word_token(&self, index: usize) -> Option<ffi::WordToken> {
        self.tokenizer.get(index).map(|word| {
            let base_time_ms = 60_000.0 / (self.config.wpm as f32);

            // Adjust for word length
            let length_factor = if word.char_count > 8 {
                1.3
            } else if word.char_count > 5 {
                1.15
            } else {
                1.0
            };

            // Apply punctuation pause
            let punct_factor =
                if self.config.pause_on_punctuation && word.has_trailing_punctuation {
                    self.config.punctuation_multiplier
                } else {
                    1.0
                };

            ffi::WordToken {
                text: word.text.clone(),
                index: index as u32,
                total: self.tokenizer.len() as u32,
                display_time_ms: (base_time_ms * length_factor * punct_factor) as u32,
            }
        })
    }
}
