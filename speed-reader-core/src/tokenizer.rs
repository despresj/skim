use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone)]
pub struct Word {
    pub text: String,
    pub has_trailing_punctuation: bool,
    pub char_count: usize,
}

pub struct Tokenizer {
    words: Vec<Word>,
}

impl Tokenizer {
    pub fn new() -> Self {
        Self { words: Vec::new() }
    }

    pub fn tokenize(&mut self, text: &str) {
        self.words = text
            .unicode_words()
            .map(|w| {
                let text = w.to_string();
                let has_trailing_punctuation = text
                    .chars()
                    .last()
                    .map(|c| matches!(c, '.' | '!' | '?' | ',' | ';' | ':'))
                    .unwrap_or(false);
                Word {
                    char_count: text.chars().count(),
                    text,
                    has_trailing_punctuation,
                }
            })
            .collect();
    }

    pub fn words(&self) -> &[Word] {
        &self.words
    }

    pub fn len(&self) -> usize {
        self.words.len()
    }

    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }

    pub fn get(&self, index: usize) -> Option<&Word> {
        self.words.get(index)
    }
}

impl Default for Tokenizer {
    fn default() -> Self {
        Self::new()
    }
}
