#[derive(Debug, PartialEq)]
pub enum LaunchIntent {
    Background,
    Palette,
    Library,
}
impl LaunchIntent {
    pub fn from_args(args: impl IntoIterator<Item = impl AsRef<str>>) -> Self {
        let mut intent = Self::Library;
        for arg in args {
            match arg.as_ref() {
                "--autostart" => return Self::Background,
                "--show-palette" => intent = Self::Palette,
                _ => {}
            }
        }
        intent
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn background_launch_never_reveals_a_window() {
        assert_eq!(
            LaunchIntent::from_args(["cue", "--autostart"]),
            LaunchIntent::Background
        );
        assert_eq!(
            LaunchIntent::from_args(["cue", "--show-palette", "--autostart"]),
            LaunchIntent::Background
        );
    }
    #[test]
    fn explicit_launch_selects_requested_surface() {
        assert_eq!(LaunchIntent::from_args(["cue"]), LaunchIntent::Library);
        assert_eq!(
            LaunchIntent::from_args(["cue", "--show-palette"]),
            LaunchIntent::Palette
        );
    }
}
