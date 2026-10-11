use serde::Deserialize;
use std::io::{Error, ErrorKind, Result};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_FRAME: usize = 16 * 1024 * 1024;

/// Client-to-daemon messages. Requests carry an id, fire-and-forget ones do not.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Msg {
    Hello {
        id: u64,
        protocol: u32,
    },
    Ping {
        id: u64,
    },
    Spawn {
        id: u64,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        command: Option<Vec<String>>,
    },
    Kill {
        id: u64,
        terminal: String,
    },
    Input {
        terminal: String,
        data: String,
    },
    Resize {
        terminal: String,
        cols: u16,
        rows: u16,
    },
}

pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Result<Vec<u8>> {
    let len = r.read_u32().await? as usize;
    if len > MAX_FRAME {
        return Err(Error::new(ErrorKind::InvalidData, "frame too large"));
    }
    let mut body = vec![0; len];
    r.read_exact(&mut body).await?;
    Ok(body)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, body: &[u8]) -> Result<()> {
    if body.len() > MAX_FRAME {
        return Err(Error::new(ErrorKind::InvalidData, "frame too large"));
    }
    w.write_all(&(body.len() as u32).to_be_bytes()).await?;
    w.write_all(body).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trip() {
        let mut wire = Vec::new();
        write_frame(&mut wire, br#"{"type":"ping","id":1}"#)
            .await
            .unwrap();
        write_frame(&mut wire, b"").await.unwrap();
        assert_eq!(&wire[..4], &[0, 0, 0, 22]);
        let mut r = &wire[..];
        assert_eq!(
            read_frame(&mut r).await.unwrap(),
            br#"{"type":"ping","id":1}"#
        );
        assert_eq!(read_frame(&mut r).await.unwrap(), b"");
        assert!(read_frame(&mut r).await.is_err());
    }

    #[tokio::test]
    async fn rejects_oversize() {
        let wire = (MAX_FRAME as u32 + 1).to_be_bytes();
        let err = read_frame(&mut &wire[..]).await.unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidData);
    }
}
