#include "MonitorBackend.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDir>

MonitorBackend::MonitorBackend(QObject* parent) : QObject(parent) {}

void MonitorBackend::setRpcUrl(const QString& url) {
    if (m_rpcClient) { m_rpcClient->stop(); delete m_rpcClient; m_rpcClient = nullptr; }
    if (url.isEmpty()) return;
    m_rpcClient = new RpcClient(url, this);
    connect(m_rpcClient, &RpcClient::updated, this, [this]{ emit stateChanged(); });
    m_rpcClient->start();
}

void MonitorBackend::setStateDir(const QString& path, bool replay) {
    if (m_stateDir == path) return;
    m_stateDir = path;

    if (m_seqTailer) { m_seqTailer->stop(); delete m_seqTailer; m_seqTailer = nullptr; }
    for (int i = 0; i < 4; ++i) {
        if (m_nodeTailers[i]) { m_nodeTailers[i]->stop(); delete m_nodeTailers[i]; m_nodeTailers[i] = nullptr; }
    }
    if (m_senderTailer) { m_senderTailer->stop(); delete m_senderTailer; m_senderTailer = nullptr; }
    if (m_receiverTailer) { m_receiverTailer->stop(); delete m_receiverTailer; m_receiverTailer = nullptr; }

    resetState();

    m_seqTailer = new LogTailer(QDir(path).filePath("sequencer.log"), replay, this);
    connect(m_seqTailer, &LogTailer::newLine, this, &MonitorBackend::onSequencerLine);
    connect(m_seqTailer, &LogTailer::fileReset, this, [this]{ resetState(); });
    m_seqTailer->start();

    for (int i = 0; i < 4; ++i) {
        m_nodeTailers[i] = new LogTailer(
            QDir(path).filePath(QStringLiteral("node%1.log").arg(i)), replay, this);
        connect(m_nodeTailers[i], &LogTailer::newLine, this, [this, i](const QString& l){ onNodeLine(i, l); });
        connect(m_nodeTailers[i], &LogTailer::fileReset, this, [this]{ resetState(); });
        m_nodeTailers[i]->start();
    }

    m_senderTailer = new LogTailer(QDir(path).filePath("chat_sender.log"), replay, this);
    connect(m_senderTailer, &LogTailer::newLine, this, [this](const QString& l){ onChatLine(true, l); });
    connect(m_senderTailer, &LogTailer::fileReset, this, [this]{ resetState(); });
    m_senderTailer->start();

    m_receiverTailer = new LogTailer(QDir(path).filePath("chat_receiver.log"), replay, this);
    connect(m_receiverTailer, &LogTailer::newLine, this, [this](const QString& l){ onChatLine(false, l); });
    connect(m_receiverTailer, &LogTailer::fileReset, this, [this]{ resetState(); });
    m_receiverTailer->start();
}

void MonitorBackend::resetState() {
    m_blockId = 0;
    for (auto& n : m_nodes) n = {};
    m_sender = {};
    m_receiver = {};
    m_markers = {};
    m_membershipRequestTime = QDateTime();
    m_chainEvents.clear();
    m_senderCorrelation.clear();
    m_nodeCorrelation.clear();
    emit stateChanged();
}

QString MonitorBackend::mixNodeStates() const {
    QJsonArray arr;
    for (int i = 0; i < 4; ++i) {
        QJsonObject o;
        o["mounted"] = m_nodes[i].mixMounted;
        o["lez"] = m_nodes[i].lezWired;
        o["kad"] = m_nodes[i].kadReady;
        o["proofs"] = m_nodes[i].proofsVerified;
        o["roots"] = m_nodes[i].rootsCount;
        arr.append(o);
    }
    return QJsonDocument(arr).toJson(QJsonDocument::Compact);
}

QString MonitorBackend::marker3NodeCounts() const {
    QJsonArray arr;
    for (int i = 0; i < 4; ++i) {
        QJsonObject o;
        o["node"] = i;
        o["proofs"] = m_nodes[i].proofsVerified;
        arr.append(o);
    }
    return QJsonDocument(arr).toJson(QJsonDocument::Compact);
}

QString MonitorBackend::nodeRootsInfo() const {
    QJsonArray arr;
    for (int i = 0; i < 4; ++i) {
        QJsonObject o;
        o["node"] = i;
        o["roots"] = m_nodes[i].rootsCount;
        arr.append(o);
    }
    return QJsonDocument(arr).toJson(QJsonDocument::Compact);
}

void MonitorBackend::onSequencerLine(const QString& line) {
    auto ev = LogParser::parseSequencerLine(line);
    if (ev.type == ParsedEvent::SeqBlockCreated)
        m_blockId = ev.intVal;
    if (ev.type != ParsedEvent::None)
        emit stateChanged();
}

void MonitorBackend::onNodeLine(int idx, const QString& line) {
    auto ev = LogParser::parseMixNodeLine(line);
    auto& node = m_nodes[idx];
    switch (ev.type) {
    case ParsedEvent::MixMounted: node.mixMounted = true; break;
    case ParsedEvent::LezWired: node.lezWired = true; break;
    case ParsedEvent::KadReady: node.kadReady = true; break;
    case ParsedEvent::GifterMounted: node.gifterMounted = true; break;
    case ParsedEvent::GifterSelfRegistered: node.gifterSelfReg = true; break;
    case ParsedEvent::GifterReqReceived:
        ++node.gifterReqsIn;
        if (!m_markers.m1_active) {
            m_markers.m1_active = true;
            m_markers.m1_requestId = ev.strVal;
            m_markers.m1_peerId = ev.strVal2;
            m_markers.m1_identityCommitment = ev.strVal3;
            m_markers.m1_timestamp = nowTimestamp();
            m_markers.m1_rawLine = LogParser::stripLogosHostPrefix(line);
        }
        addCorrelation(m_nodeCorrelation,
            QStringLiteral("N%1 GIFTER").arg(idx),
            QStringLiteral("handling request id=%1 peer=%2").arg(ev.strVal, ev.strVal2));
        break;
    case ParsedEvent::GifterReqSucceeded:
        ++node.gifterReqsOk;
        if (m_markers.m2_active && ev.strVal.length() > 0)
            m_markers.m2_requestId = ev.strVal;
        addCorrelation(m_nodeCorrelation,
            QStringLiteral("N%1 GIFTER").arg(idx),
            QStringLiteral("registration succeeded leaf=%1").arg(ev.intVal));
        break;
    case ParsedEvent::GifterReqFailed:
        ++node.gifterReqsFail;
        addCorrelation(m_nodeCorrelation,
            QStringLiteral("N%1 GIFTER").arg(idx),
            QStringLiteral("registration FAILED: %1").arg(ev.strVal));
        break;
    case ParsedEvent::ProofVerified:
        ++node.proofsVerified;
        ++m_markers.m3_verifyCount;
        if (!m_markers.m3_active) {
            m_markers.m3_active = true;
            m_markers.m3_epoch = ev.intVal;
            m_markers.m3_nullifier = ev.strVal;
            m_markers.m3_rawLine = LogParser::stripLogosHostPrefix(line);
        }
        addCorrelation(m_nodeCorrelation,
            QStringLiteral("N%1 VERIFY").arg(idx),
            QStringLiteral("proof OK epoch=%1 null=%2").arg(ev.intVal).arg(ev.strVal));
        break;
    case ParsedEvent::TotalProofsVerified:
        node.proofsVerified = ev.intVal;
        if (!m_markers.m3_active && ev.intVal > 0) {
            m_markers.m3_active = true;
            m_markers.m3_rawLine = LogParser::stripLogosHostPrefix(line);
        }
        m_markers.m3_verifyCount = 0;
        for (int i = 0; i < 4; ++i) m_markers.m3_verifyCount += m_nodes[i].proofsVerified;
        break;
    case ParsedEvent::ProofGenerated:
        addCorrelation(m_nodeCorrelation,
            QStringLiteral("N%1 PROOF").arg(idx),
            QStringLiteral("Generated RLN proof epoch=%1").arg(ev.intVal));
        break;
    case ParsedEvent::GifterAuthBounce:
        addCorrelation(m_nodeCorrelation,
            QStringLiteral("N%1 AUTH").arg(idx),
            QStringLiteral("BOUNCE: %1").arg(ev.strVal));
        break;
    case ParsedEvent::RlnRootsPolled:
        node.rootsCount = ev.intVal;
        break;
    default: return;
    }
    emit stateChanged();
}

void MonitorBackend::onChatLine(bool isSender, const QString& line) {
    auto ev = LogParser::parseChatLine(line);
    auto& chat = isSender ? m_sender : m_receiver;
    switch (ev.type) {
    case ParsedEvent::ChatInit: chat.phase = "init"; break;
    case ParsedEvent::ChatStart: chat.phase = "start"; break;
    case ParsedEvent::ChatMembershipRequested:
        chat.phase = "request";
        if (isSender) {
            m_membershipRequestTime = QDateTime::currentDateTime();
            addCorrelation(m_senderCorrelation, QStringLiteral("SENDER"),
                QStringLiteral("requesting RLN membership from gifter"));
        }
        break;
    case ParsedEvent::ChatMembershipGranted:
        chat.phase = QStringLiteral("opt:%1").arg(ev.intVal);
        chat.optLeaf = ev.intVal;
        if (isSender) {
            m_markers.m2_active = true;
            m_markers.m2_leafIndex = ev.intVal;
            m_markers.m2_rawLine = LogParser::stripLogosHostPrefix(line);
            addCorrelation(m_senderCorrelation, QStringLiteral("SENDER"),
                QStringLiteral("RLN membership granted leaf=%1").arg(ev.intVal));
        }
        break;
    case ParsedEvent::ChatMembershipConfirmed:
        chat.phase = QStringLiteral("conf:%1").arg(ev.intVal);
        chat.authLeaf = ev.intVal;
        if (isSender) {
            m_markers.m2_onChainConfirmed = true;
            if (m_membershipRequestTime.isValid())
                m_markers.m2_elapsedSecs = m_membershipRequestTime.secsTo(QDateTime::currentDateTime());
            addCorrelation(m_senderCorrelation, QStringLiteral("SENDER"),
                QStringLiteral("membership confirmed on-chain leaf=%1").arg(ev.intVal));
        }
        break;
    case ParsedEvent::ChatSendResult:
        if (ev.boolVal) {
            ++chat.msgOut;
            if (isSender) {
                chat.phase = "msg_sent";
                addCorrelation(m_senderCorrelation, QStringLiteral("SENDER"),
                    QStringLiteral("message sent (#%1)").arg(chat.msgOut));
            }
        }
        break;
    case ParsedEvent::ChatNewMessage:
        ++chat.msgIn;
        break;
    case ParsedEvent::ChatPeerStatus:
        chat.peers = ev.intVal;
        chat.mixReady = ev.boolVal;
        chat.mixPool = ev.intVal2;
        break;
    case ParsedEvent::ProofGenerated:
        if (isSender) {
            addCorrelation(m_senderCorrelation, QStringLiteral("SENDER"),
                QStringLiteral("Generated RLN proof epoch=%1").arg(ev.intVal));
        }
        break;
    case ParsedEvent::RlnRootsPolled:
        break;
    default: return;
    }
    emit stateChanged();
}

void MonitorBackend::addCorrelation(ChainEventModel& model, const QString& label, const QString& detail) {
    model.prepend(nowTimestamp(), label, detail);
}

QString MonitorBackend::nowTimestamp() const {
    return QDateTime::currentDateTime().toString("HH:mm:ss");
}
