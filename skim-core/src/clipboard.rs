use arboard::Clipboard;

pub struct ClipboardManager {
    clipboard: Option<Clipboard>,
}

impl ClipboardManager {
    pub fn new() -> Self {
        Self {
            clipboard: Clipboard::new().ok(),
        }
    }

    pub fn get_text(&mut self) -> Option<String> {
        self.clipboard
            .as_mut()
            .and_then(|cb| cb.get_text().ok())
            .filter(|s| !s.trim().is_empty())
    }

    pub fn has_text(&mut self) -> bool {
        self.get_text().is_some()
    }
}

impl Default for ClipboardManager {
    fn default() -> Self {
        Self::new()
    }
}
