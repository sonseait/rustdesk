use std::{
    io::{BufRead, BufReader, Write},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream},
    time::Duration,
};

use anyhow::{ensure, Context, Result};

pub fn check(mut address: SocketAddr) -> Result<()> {
    if address.ip().is_unspecified() {
        address.set_ip(match address.ip() {
            IpAddr::V4(_) => IpAddr::V4(Ipv4Addr::LOCALHOST),
            IpAddr::V6(_) => IpAddr::V6(Ipv6Addr::LOCALHOST),
        });
    }
    let timeout = Duration::from_secs(2);
    let mut stream = TcpStream::connect_timeout(&address, timeout)
        .context("healthcheck could not connect to the control plane")?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    write!(
        stream,
        "GET /healthz HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n"
    )?;
    let mut status = String::new();
    BufReader::new(stream).read_line(&mut status)?;
    ensure!(
        status.split_whitespace().nth(1) == Some("200"),
        "healthcheck failed: {}",
        status.trim()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;

    use super::*;

    #[test]
    fn healthcheck_requires_a_healthy_http_response() {
        for (status, healthy) in [("200 OK", true), ("503 Service Unavailable", false)] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let mut address = listener.local_addr().unwrap();
            address.set_ip(Ipv4Addr::UNSPECIFIED.into());
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request = String::new();
                reader.read_line(&mut request).unwrap();
                assert_eq!(request, "GET /healthz HTTP/1.1\r\n");
                loop {
                    request.clear();
                    assert_ne!(reader.read_line(&mut request).unwrap(), 0);
                    if request == "\r\n" {
                        break;
                    }
                }
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
                .unwrap();
            });
            assert_eq!(check(address).is_ok(), healthy);
            server.join().unwrap();
        }
    }
}
