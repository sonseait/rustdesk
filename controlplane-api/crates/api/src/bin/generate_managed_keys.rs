use ed25519_dalek::SigningKey;
use rand_core::OsRng;

fn main() {
    let credential_key = SigningKey::generate(&mut OsRng);
    let deployment_key = SigningKey::generate(&mut OsRng);

    println!("# CP only - keep these values secret and stable after deployment.");
    println!(
        "DEVICE_CREDENTIAL_SIGNING_KEY={}",
        hex::encode(credential_key.to_bytes())
    );
    println!(
        "BOOTSTRAP_CONFIG_SIGNING_KEY={}",
        hex::encode(deployment_key.to_bytes())
    );
    println!();
    println!("# Client build only - this is safe to embed in the client.");
    println!(
        "MANAGED_CP_CONFIG_PUBLIC_KEY={}",
        hex::encode(deployment_key.verifying_key().as_bytes())
    );
}
