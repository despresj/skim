#[derive(Debug, Clone)]
pub struct Word {
    pub text: String,
    pub has_trailing_punctuation: bool,
    pub punctuation_type: PunctuationType,
    pub char_count: usize,
    pub word_type: WordType,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum WordType {
    Normal,
    Numeral,    // Contains digits (harder to process visually)
    AllCaps,    // ALL UPPERCASE (harder to read)
    Hyphenated, // Compound-word (treat as longer)
    Mixed,      // Mix of letters and numbers like "COVID19"
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PunctuationType {
    None,
    Comma,      // , ; :
    Period,     // .
    Question,   // ?
    Exclamation,// !
    Ellipsis,   // ...
}

impl WordType {
    /// Returns the complexity multiplier for this word type
    pub fn complexity_multiplier(&self) -> f32 {
        match self {
            WordType::Normal => 1.0,
            WordType::Numeral => 1.4,    // Numbers need more processing time
            WordType::AllCaps => 1.25,   // All caps are harder to read
            WordType::Hyphenated => 1.3, // Compound words need more time
            WordType::Mixed => 1.35,     // Mixed alphanumeric (like "COVID19")
        }
    }
}

impl PunctuationType {
    /// Returns the pause multiplier for this punctuation type
    pub fn pause_multiplier(&self) -> f32 {
        match self {
            PunctuationType::None => 1.0,
            PunctuationType::Comma => 1.5,        // Short pause
            PunctuationType::Period => 2.0,       // Medium pause
            PunctuationType::Question => 2.2,     // Slightly longer
            PunctuationType::Exclamation => 2.2,  // Slightly longer
            PunctuationType::Ellipsis => 2.5,     // Longest pause
        }
    }
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
            .split_whitespace()
            .filter(|s| !s.is_empty())
            .map(|w| {
                let text = w.to_string();
                let (has_trailing_punctuation, punctuation_type) = Self::analyze_punctuation(&text);
                let word_type = Self::analyze_word_type(&text);
                Word {
                    char_count: text.chars().count(),
                    text,
                    has_trailing_punctuation,
                    punctuation_type,
                    word_type,
                }
            })
            .collect();
    }

    fn analyze_punctuation(text: &str) -> (bool, PunctuationType) {
        // Check for ellipsis first
        if text.ends_with("...") || text.ends_with("…") {
            return (true, PunctuationType::Ellipsis);
        }

        // Check last character for punctuation
        if let Some(last_char) = text.chars().last() {
            match last_char {
                '.' => (true, PunctuationType::Period),
                '?' => (true, PunctuationType::Question),
                '!' => (true, PunctuationType::Exclamation),
                ',' | ';' | ':' => (true, PunctuationType::Comma),
                _ => (false, PunctuationType::None),
            }
        } else {
            (false, PunctuationType::None)
        }
    }

    fn analyze_word_type(text: &str) -> WordType {
        // Strip punctuation for analysis
        let clean: String = text.chars().filter(|c| c.is_alphanumeric() || *c == '-').collect();
        if clean.is_empty() {
            return WordType::Normal;
        }

        let has_letters = clean.chars().any(|c| c.is_alphabetic());
        let has_digits = clean.chars().any(|c| c.is_ascii_digit());
        let has_hyphen = clean.contains('-') && clean.len() > 1;

        // Check for hyphenated compound words
        if has_hyphen && has_letters {
            return WordType::Hyphenated;
        }

        // Check for mixed alphanumeric (like "COVID19", "iPhone12")
        if has_letters && has_digits {
            return WordType::Mixed;
        }

        // Check for pure numerals (like "2024", "$500", "3.14")
        if has_digits && !has_letters {
            return WordType::Numeral;
        }

        // Check for ALL CAPS (at least 2 letters, all uppercase)
        let letters: Vec<char> = clean.chars().filter(|c| c.is_alphabetic()).collect();
        if letters.len() >= 2 && letters.iter().all(|c| c.is_uppercase()) {
            return WordType::AllCaps;
        }

        WordType::Normal
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
