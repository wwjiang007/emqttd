# EMQ X Broker

[![GitHub Release](https://img.shields.io/github/release/emqx/emqx?color=brightgreen)](https://github.com/emqx/emqx/releases)
[![Build Status](https://travis-ci.org/emqx/emqx.svg)](https://travis-ci.org/emqx/emqx)
[![Coverage Status](https://coveralls.io/repos/github/emqx/emqx/badge.svg)](https://coveralls.io/github/emqx/emqx)
[![Docker Pulls](https://img.shields.io/docker/pulls/emqx/emqx)](https://hub.docker.com/r/emqx/emqx)
[![Slack Invite](<https://slack-invite.emqx.io/badge.svg>)](https://slack-invite.emqx.io)
[![Twitter](https://img.shields.io/badge/Twitter-EMQ-1DA1F2?logo=twitter)](https://twitter.com/EMQTech)
[![YouTube](https://img.shields.io/badge/Subscribe-EMQ-FF0000?logo=youtube)](https://www.youtube.com/channel/UC5FjR77ErAxvZENEWzQaO5Q)

[![The best IoT MQTT open source team looks forward to your joining](https://www.emqx.io/static/img/github_readme_en_bg.png)](https://www.emqx.io/careers)

[English](./README.md) | [简体中文](./README-CN.md) | 日本語 | [русский](./README-RU.md)

*EMQ X* は、高い拡張性と可用性をもつ、分散型のMQTTブローカーです。数千万のクライアントを同時に処理するIoT、M2M、モバイルアプリケーション向けです。

version 3.0 以降、*EMQ X* は MQTT V5.0 の仕様を完全にサポートしており、MQTT V3.1およびV3.1.1とも下位互換性があります。
MQTT-SN、CoAP、LwM2M、WebSocket、STOMPなどの通信プロトコルをサポートしています。 MQTTの同時接続数は1つのクラスター上で1,000万以上にまでスケールできます。

- 新機能の一覧については、[EMQ Xリリースノート](https://github.com/emqx/emqx/releases)を参照してください。
- 詳細はこちら[EMQ X公式ウェブサイト](https://www.emqx.io/)をご覧ください。

## インストール

*EMQ X* はクロスプラットフォームで、Linux、Unix、macOS、Windowsをサポートしています。
そのため、x86_64アーキテクチャサーバー、またはRaspberryPiなどのARMデバイスに *EMQ X* をデプロイすることもできます。

Windows上における *EMQ X* のビルドと実行については、[Windows.md](./Windows.md)をご参照ください。

#### Docker イメージによる EMQ X のインストール

```
docker run -d --name emqx -p 1883:1883 -p 8083:8083 -p 8883:8883 -p 8084:8084 -p 18083:18083 emqx/emqx
```

#### バイナリパッケージによるインストール

それぞれのOSに対応したバイナリソフトウェアパッケージは、[EMQ Xのダウンロード](https://www.emqx.io/downloads)ページから取得できます。

- [シングルノードインストール](https://docs.emqx.io/broker/latest/en/getting-started/installation.html)
- [マルチノードインストール](https://docs.emqx.io/broker/latest/en/advanced/cluster.html)

## ソースからビルド

version 3.0 以降の *EMQ X* をビルドするには Erlang/OTP R21+ が必要です。

version 4.3 以降の場合：

```bash
git clone https://github.com/emqx/emqx-rel.git
cd emqx-rel
make
_build/emqx/rel/emqx/bin/emqx console
```

## クイックスタート

emqx をソースコードからビルドした場合は、
`cd _build/emqx/rel/emqx`でリリースビルドのディレクトリに移動してください。

リリースパッケージからインストールした場合は、インストール先のルートディレクトリに移動してください。

```
# Start emqx
./bin/emqx start

# Check Status
./bin/emqx_ctl status

# Stop emqx
./bin/emqx stop
```

*EMQ X* の起動後、ブラウザで http://localhost:18083 にアクセスするとダッシュボードが表示されます。

## テスト

### 全てのテストケースを実行する

```
make eunit ct
```

### common test の一部を実行する

```bash
make apps/emqx_bridge_mqtt-ct
```

### Dialyzer
##### アプリケーションの型情報を解析する
```
make dialyzer
```

##### 特定のアプリケーションのみ解析する（アプリケーション名をコンマ区切りで入力）
```
DIALYZER_ANALYSE_APP=emqx_lwm2m,emqx_authz make dialyzer
```

## コミュニティ

### FAQ

よくある質問については、[EMQ X FAQ](https://docs.emqx.io/broker/latest/en/faq/faq.html)をご確認ください。

### 質問する

質問や知識共有の場として[GitHub Discussions](https://github.com/emqx/emqx/discussions)を用意しています。

### 提案

大規模な改善のご提案がある場合は、[EIP](https://github.com/emqx/eip)にPRをどうぞ。

### 自作プラグイン

プラグインを自作することができます。[lib-extra/README.md](./lib-extra/README.md)をご確認ください。


## MQTTの仕様について

下記のサイトで、MQTTのプロトコルについて学習・確認できます。

[MQTT Version 3.1.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html)

[MQTT Version 5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/cs02/mqtt-v5.0-cs02.html)

[MQTT SN](https://www.oasis-open.org/committees/download.php/66091/MQTT-SN_spec_v1.2.pdf)

## License

Apache License 2.0, see [LICENSE](https://github.com/emqx/MQTTX/blob/master/LICENSE).
