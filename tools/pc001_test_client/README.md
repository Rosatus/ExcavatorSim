# PC001 TCP 测试客户端

用于在本机连接 ExcavatorSim Gateway 的 PC001 TCP Server，完成 `who` →
`PC001` 握手并按 CAN identity/channel 聚合显示接收到的帧。该工具只接收，
不会修改 Gateway 配置或发送 CAN 帧。

## 源码运行

```powershell
cd tools/pc001_test_client
uv run --python 3.12 python -m pc001_test_client
```

默认连接 `127.0.0.1:5678`。也可在界面中修改，或通过参数指定：

```powershell
uv run --python 3.12 python -m pc001_test_client --host 127.0.0.1 --port 5678
```

## 测试和检查

```powershell
uv run --python 3.12 --group dev python -m unittest discover -s tests
uv run --python 3.12 --group dev ruff check .
uv run --python 3.12 --group dev mypy
```

## Windows 打包

```powershell
uv run --python 3.12 --group dev python build_windows.py
```

产物位于：

- `dist/pc001_test_client/PC001TestClient/PC001TestClient.exe`
- `dist/pc001_test_client/PC001TestClient-windows-x86_64.zip`

该目录是独立测试工具，不会被复制到 Gateway 或 Godot 正式发行包。

