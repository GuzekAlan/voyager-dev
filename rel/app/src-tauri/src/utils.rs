use rand::RngExt;
use rand::distr::Alphanumeric;
use std::io::{Error, ErrorKind, Result};
use std::net::TcpListener;
use std::path::Path;

const SECRET_KEY_BASE_FILE: &str = "secret_key_base";
/// Length, in characters, of the generated `SECRET_KEY_BASE`. Matches the
/// 64-character default produced by Phoenix's `mix phx.gen.secret`.
const SECRET_KEY_BASE_LEN: usize = 64;

/// Returns the first TCP port available on `127.0.0.1` at or after `start`.
pub fn available_port(start: u16) -> Result<u16> {
    (start..=u16::MAX)
        .find(|&port| TcpListener::bind(("127.0.0.1", port)).is_ok())
        .ok_or_else(|| Error::new(ErrorKind::AddrNotAvailable, "no available localhost port"))
}

/// Reads the persisted `SECRET_KEY_BASE` from `data_dir`, generating and
/// persisting a new one when it is missing or not the expected length.
pub fn secret_key_base(data_dir: &Path) -> String {
    let path = data_dir.join(SECRET_KEY_BASE_FILE);

    match std::fs::read_to_string(&path) {
        Ok(secret) if secret.trim().len() == SECRET_KEY_BASE_LEN => secret.trim().to_string(),
        _ => generate_secret_key_base(&path),
    }
}

fn generate_secret_key_base(path: &Path) -> String {
    let secret = random_secret(SECRET_KEY_BASE_LEN);
    std::fs::write(path, &secret).expect("failed to persist SECRET_KEY_BASE");
    secret
}

/// Builds a string of `len` random ASCII alphanumeric characters.
fn random_secret(len: usize) -> String {
    rand::rng()
        .sample_iter(Alphanumeric)
        .take(len)
        .map(char::from)
        .collect()
}

/// Best-effort OS appearance (`"dark"` / `"light"`). Falls back to `"dark"`
/// when detection fails.
pub fn os_theme_hint() -> &'static str {
    match dark_light::detect() {
        Ok(dark_light::Mode::Light) | Ok(dark_light::Mode::Unspecified) => "light",
        Ok(dark_light::Mode::Dark) | Err(_) => "dark",
    }
}

#[cfg(target_os = "linux")]
const TRAY_WATCHER: &str = "org.kde.StatusNotifierWatcher";

/// Whether the desktop can show a tray icon. Linux needs a StatusNotifierItem host,
/// which stock GNOME lacks without the AppIndicator extension.
#[cfg(target_os = "linux")]
pub fn tray_host_available() -> bool {
    use gtk::glib::ToVariant;

    appindicator_available()
        && session_bus()
            .and_then(|bus| {
                bus.call_sync(
                    Some("org.freedesktop.DBus"),
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "NameHasOwner",
                    Some(&(TRAY_WATCHER,).to_variant()),
                    None,
                    gtk::gio::DBusCallFlags::NONE,
                    1000,
                    gtk::gio::Cancellable::NONE,
                )
                .ok()
            })
            .and_then(|reply| reply.get::<(bool,)>())
            .is_some_and(|(owned,)| owned)
}

/// Calls `on_lost` on the main thread whenever the tray host leaves the session bus.
/// Must run on the main thread.
#[cfg(target_os = "linux")]
pub fn on_tray_host_lost(on_lost: impl Fn() + 'static) {
    let Some(bus) = session_bus() else {
        return;
    };
    bus.signal_subscribe(
        Some("org.freedesktop.DBus"),
        Some("org.freedesktop.DBus"),
        Some("NameOwnerChanged"),
        Some("/org/freedesktop/DBus"),
        Some(TRAY_WATCHER),
        gtk::gio::DBusSignalFlags::NONE,
        move |_, _, _, _, _, params| {
            if params
                .get::<(String, String, String)>()
                .is_some_and(|(_, _, new_owner)| new_owner.is_empty())
            {
                on_lost();
            }
        },
    );
    // GIO drops the shared session bus, and the subscription with it, once nothing holds it.
    std::mem::forget(bus);
}

/// Shows a desktop notification; fire and forget.
#[cfg(target_os = "linux")]
pub fn notify(summary: &str, body: &str) {
    use gtk::glib::{ToVariant, Variant, VariantDict};

    let Some(bus) = session_bus() else {
        return;
    };
    let actions: Vec<String> = Vec::new();
    let params = Variant::tuple_from_iter([
        "Voyager".to_variant(),
        0u32.to_variant(),
        "".to_variant(),
        summary.to_variant(),
        body.to_variant(),
        actions.to_variant(),
        VariantDict::new(None).end(),
        (-1i32).to_variant(),
    ]);
    bus.call(
        Some("org.freedesktop.Notifications"),
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        Some(&params),
        None,
        gtk::gio::DBusCallFlags::NONE,
        -1,
        gtk::gio::Cancellable::NONE,
        |_| {},
    );
}

/// Tauri's tray loads this library at runtime and panics when the distro lacks it.
#[cfg(target_os = "linux")]
pub fn appindicator_available() -> bool {
    [
        "libayatana-appindicator3.so.1",
        "libappindicator3.so.1",
        "libayatana-appindicator3.so",
        "libappindicator3.so",
    ]
    .into_iter()
    .any(|name| unsafe { libloading::Library::new(name) }.is_ok())
}

#[cfg(target_os = "linux")]
fn session_bus() -> Option<gtk::gio::DBusConnection> {
    gtk::gio::bus_get_sync(gtk::gio::BusType::Session, gtk::gio::Cancellable::NONE).ok()
}

#[cfg(not(target_os = "linux"))]
pub fn tray_host_available() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn available_port_skips_bound_ports() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let occupied_port = listener.local_addr().unwrap().port();

        let port = available_port(occupied_port).unwrap();

        assert!(port > occupied_port);
    }

    #[test]
    fn secret_key_base_generates_and_reuses_persisted_secret() {
        let data_dir = temp_data_dir("secret-reuse");
        std::fs::create_dir_all(&data_dir).unwrap();

        let secret = secret_key_base(&data_dir);
        let persisted_secret =
            std::fs::read_to_string(data_dir.join(SECRET_KEY_BASE_FILE)).unwrap();
        let reused_secret = secret_key_base(&data_dir);

        assert_eq!(secret.len(), SECRET_KEY_BASE_LEN);
        assert!(secret.chars().all(|char| char.is_ascii_alphanumeric()));
        assert_eq!(secret, persisted_secret);
        assert_eq!(secret, reused_secret);

        std::fs::remove_dir_all(data_dir).unwrap();
    }

    #[test]
    fn secret_key_base_replaces_invalid_persisted_secret() {
        let data_dir = temp_data_dir("secret-invalid");
        std::fs::create_dir_all(&data_dir).unwrap();
        std::fs::write(data_dir.join(SECRET_KEY_BASE_FILE), "too-short").unwrap();

        let secret = secret_key_base(&data_dir);

        assert_eq!(secret.len(), SECRET_KEY_BASE_LEN);
        assert_ne!(secret, "too-short");

        std::fs::remove_dir_all(data_dir).unwrap();
    }

    #[test]
    fn secret_key_base_replaces_wrong_length_persisted_secret() {
        let data_dir = temp_data_dir("secret-wrong-length");
        std::fs::create_dir_all(&data_dir).unwrap();
        let too_long = "a".repeat(SECRET_KEY_BASE_LEN + 1);
        std::fs::write(data_dir.join(SECRET_KEY_BASE_FILE), &too_long).unwrap();

        let secret = secret_key_base(&data_dir);

        assert_eq!(secret.len(), SECRET_KEY_BASE_LEN);
        assert_ne!(secret, too_long);

        std::fs::remove_dir_all(data_dir).unwrap();
    }

    fn temp_data_dir(test_name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "voyager-utils-test-{test_name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        path
    }
}
