use hbb_common::{bail, bytes::BytesMut, protobuf::Message, rendezvous_proto::*, tcp::{Encrypt, FramedStream}, timeout, ResultType};
use sodiumoxide::crypto::{box_, sign};

pub(crate) async fn accept(
    stream: &mut FramedStream,
    signing_key: Option<&sign::SecretKey>,
) -> ResultType<Option<BytesMut>> {
    let ephemeral = if let Some(sk) = signing_key {
        let (pk, secret) = box_::gen_keypair();
        let mut offer = RendezvousMessage::new();
        offer.set_key_exchange(KeyExchange {
            keys: vec![sign::sign(&pk.0, sk).into()],
            ..Default::default()
        });
        timeout(3000, stream.send(&offer)).await??;
        Some(secret)
    } else {
        None
    };
    let first = match timeout(30_000, stream.next()).await? {
        Some(result) => result?,
        None => return Ok(None),
    };
    let message = RendezvousMessage::parse_from_bytes(&first)?;
    if !message.has_key_exchange() {
        // Existing clients send their request first and ignore the key offer.
        return Ok(Some(first));
    }
    let secret = match ephemeral {
        Some(secret) => secret,
        None => bail!("Unexpected key exchange without a server signing key"),
    };
    let keys = &message.key_exchange().keys;
    if keys.len() != 2 {
        bail!("Invalid client key exchange");
    }
    stream.set_key(Encrypt::decode(&keys[1], &keys[0], &secret)?);
    match timeout(30_000, stream.next()).await? {
        Some(result) => Ok(Some(result?)),
        None => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::tokio;
    use sodiumoxide::crypto::{box_, secretbox};

    #[tokio::test]
    async fn signed_handshake_and_encrypted_request_round_trip() {
        let (pk, sk) = sign::gen_keypair();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (tcp, addr) = listener.accept().await.unwrap();
            let mut stream = FramedStream::from(tcp, addr);
            let first = accept(&mut stream, Some(&sk)).await.unwrap().unwrap();
            assert!(stream.is_secured());
            let request = RendezvousMessage::parse_from_bytes(&first).unwrap();
            assert!(request.has_test_nat_request());
            stream.send(&request).await.unwrap();
        });
        let mut client = FramedStream::new(addr, None, 1000).await.unwrap();
        let bytes = hbb_common::timeout(1000, client.next()).await.expect("server must send KeyExchange before reading client data").unwrap().unwrap();
        let offer = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
        assert!(offer.has_key_exchange());
        let server_pk = sign::verify(&offer.key_exchange().keys[0], &pk).unwrap();
        let server_pk = box_::PublicKey::from_slice(&server_pk).unwrap();
        let (our_pk, our_sk) = box_::gen_keypair();
        let key = secretbox::gen_key();
        let encrypted = box_::seal(&key.0, &box_::Nonce([0; box_::NONCEBYTES]), &server_pk, &our_sk);
        let mut reply = RendezvousMessage::new();
        reply.set_key_exchange(KeyExchange { keys: vec![our_pk.0.to_vec().into(), encrypted.into()], ..Default::default() });
        client.send(&reply).await.unwrap();
        client.set_key(key);
        let mut request = RendezvousMessage::new();
        request.set_test_nat_request(TestNatRequest::new());
        client.send(&request).await.unwrap();
        let response = hbb_common::timeout(1000, client.next()).await.unwrap().unwrap().unwrap();
        assert_eq!(RendezvousMessage::parse_from_bytes(&response).unwrap(), request);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn request_first_clients_remain_unencrypted() {
        for signed in [false, true] {
            let (_, sk) = sign::gen_keypair();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (tcp, addr) = listener.accept().await.unwrap();
                let mut stream = FramedStream::from(tcp, addr);
                let first = accept(&mut stream, if signed { Some(&sk) } else { None }).await.unwrap().unwrap();
                assert!(!stream.is_secured());
                let request = RendezvousMessage::parse_from_bytes(&first).unwrap();
                stream.send(&request).await.unwrap();
            });
            let mut client = FramedStream::new(addr, None, 1000).await.unwrap();
            let mut request = RendezvousMessage::new();
            request.set_test_nat_request(TestNatRequest::new());
            client.send(&request).await.unwrap();
            loop {
                let bytes = hbb_common::timeout(1000, client.next()).await.unwrap().unwrap().unwrap();
                let response = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
                if response.has_key_exchange() { continue; }
                assert_eq!(response, request);
                break;
            }
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn malformed_key_exchange_is_rejected_without_plaintext_fallback() {
        let (_, sk) = sign::gen_keypair();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (tcp, addr) = listener.accept().await.unwrap();
            let mut stream = FramedStream::from(tcp, addr);
            assert!(accept(&mut stream, Some(&sk)).await.is_err());
            assert!(!stream.is_secured());
        });
        let mut client = FramedStream::new(addr, None, 1000).await.unwrap();
        client.next().await.unwrap().unwrap();
        let mut reply = RendezvousMessage::new();
        reply.set_key_exchange(KeyExchange { keys: vec![vec![0; 32].into(), vec![0; 48].into()], ..Default::default() });
        client.send(&reply).await.unwrap();
        server.await.unwrap();
    }
}
