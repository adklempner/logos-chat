#pragma once
#include <QObject>
#include <QTimer>
#include <QDateTime>
#include <QJsonArray>
#include <QStringList>
#include "LogTailer.h"
#include "LogParser.h"
#include "ChainEventModel.h"
#include "RpcClient.h"

class MonitorBackend : public QObject {
    Q_OBJECT

    Q_PROPERTY(int blockId READ blockId NOTIFY stateChanged)
    Q_PROPERTY(int rpcBlockId READ rpcBlockId NOTIFY stateChanged)
    Q_PROPERTY(bool rpcReachable READ rpcReachable NOTIFY stateChanged)

    Q_PROPERTY(QString mixNodeStates READ mixNodeStates NOTIFY stateChanged)
    Q_PROPERTY(bool gifterMounted READ gifterMounted NOTIFY stateChanged)

    Q_PROPERTY(bool marker1Active READ marker1Active NOTIFY stateChanged)
    Q_PROPERTY(QString marker1RequestId READ marker1RequestId NOTIFY stateChanged)
    Q_PROPERTY(QString marker1PeerId READ marker1PeerId NOTIFY stateChanged)
    Q_PROPERTY(QString marker1IdCommitment READ marker1IdCommitment NOTIFY stateChanged)
    Q_PROPERTY(QString marker1Timestamp READ marker1Timestamp NOTIFY stateChanged)
    Q_PROPERTY(QString marker1RawLine READ marker1RawLine NOTIFY stateChanged)

    Q_PROPERTY(bool marker2Active READ marker2Active NOTIFY stateChanged)
    Q_PROPERTY(int marker2LeafIndex READ marker2LeafIndex NOTIFY stateChanged)
    Q_PROPERTY(QString marker2RequestId READ marker2RequestId NOTIFY stateChanged)
    Q_PROPERTY(bool marker2Confirmed READ marker2Confirmed NOTIFY stateChanged)
    Q_PROPERTY(double marker2ElapsedSecs READ marker2ElapsedSecs NOTIFY stateChanged)
    Q_PROPERTY(QString marker2RawLine READ marker2RawLine NOTIFY stateChanged)

    Q_PROPERTY(bool marker3Active READ marker3Active NOTIFY stateChanged)
    Q_PROPERTY(int marker3Epoch READ marker3Epoch NOTIFY stateChanged)
    Q_PROPERTY(QString marker3Nullifier READ marker3Nullifier NOTIFY stateChanged)
    Q_PROPERTY(int marker3VerifyCount READ marker3VerifyCount NOTIFY stateChanged)
    Q_PROPERTY(QString marker3NodeCounts READ marker3NodeCounts NOTIFY stateChanged)
    Q_PROPERTY(QString marker3RawLine READ marker3RawLine NOTIFY stateChanged)

    Q_PROPERTY(QString senderPhase READ senderPhase NOTIFY stateChanged)
    Q_PROPERTY(int senderMsgOut READ senderMsgOut NOTIFY stateChanged)

    Q_PROPERTY(QString nodeRootsInfo READ nodeRootsInfo NOTIFY stateChanged)

public:
    explicit MonitorBackend(QObject* parent = nullptr);

    Q_INVOKABLE void setStateDir(const QString& path, bool replay = false);
    Q_INVOKABLE void setRpcUrl(const QString& url);

    int blockId() const { return m_blockId; }
    int rpcBlockId() const { return m_rpcClient ? m_rpcClient->lastBlockId() : -1; }
    bool rpcReachable() const { return m_rpcClient ? m_rpcClient->reachable() : false; }

    QString mixNodeStates() const;
    bool gifterMounted() const { return m_nodes[0].gifterMounted; }

    bool marker1Active() const { return m_markers.m1_active; }
    QString marker1RequestId() const { return m_markers.m1_requestId; }
    QString marker1PeerId() const { return m_markers.m1_peerId; }
    QString marker1IdCommitment() const { return m_markers.m1_identityCommitment; }
    QString marker1Timestamp() const { return m_markers.m1_timestamp; }
    QString marker1RawLine() const { return m_markers.m1_rawLine; }

    bool marker2Active() const { return m_markers.m2_active; }
    int marker2LeafIndex() const { return m_markers.m2_leafIndex; }
    QString marker2RequestId() const { return m_markers.m2_requestId; }
    bool marker2Confirmed() const { return m_markers.m2_onChainConfirmed; }
    double marker2ElapsedSecs() const { return m_markers.m2_elapsedSecs; }
    QString marker2RawLine() const { return m_markers.m2_rawLine; }

    bool marker3Active() const { return m_markers.m3_active; }
    int marker3Epoch() const { return m_markers.m3_epoch; }
    QString marker3Nullifier() const { return m_markers.m3_nullifier; }
    int marker3VerifyCount() const { return m_markers.m3_verifyCount; }
    QString marker3NodeCounts() const;
    QString marker3RawLine() const { return m_markers.m3_rawLine; }

    QString senderPhase() const { return m_sender.phase; }
    int senderMsgOut() const { return m_sender.msgOut; }

    QString nodeRootsInfo() const;

    ChainEventModel* chainEventModel() { return &m_chainEvents; }
    ChainEventModel* senderCorrelationModel() { return &m_senderCorrelation; }
    ChainEventModel* nodeCorrelationModel() { return &m_nodeCorrelation; }

signals:
    void stateChanged();

private slots:
    void onSequencerLine(const QString& line);
    void onNodeLine(int idx, const QString& line);
    void onChatLine(bool isSender, const QString& line);

private:
    void resetState();
    void addCorrelation(ChainEventModel& model, const QString& label, const QString& detail);
    QString nowTimestamp() const;

    struct NodeState {
        bool mixMounted = false;
        bool lezWired = false;
        bool kadReady = false;
        bool gifterMounted = false;
        bool gifterSelfReg = false;
        int gifterReqsIn = 0;
        int gifterReqsOk = 0;
        int gifterReqsFail = 0;
        int proofsVerified = 0;
        int rootsCount = 0;
    };

    struct ChatState {
        QString phase = QStringLiteral("---");
        int optLeaf = -1;
        int authLeaf = -1;
        int peers = 0;
        bool mixReady = false;
        int mixPool = 0;
        int msgOut = 0;
        int msgIn = 0;
    };

    struct MarkerState {
        bool m1_active = false;
        QString m1_requestId;
        QString m1_peerId;
        QString m1_identityCommitment;
        QString m1_timestamp;
        QString m1_rawLine;

        bool m2_active = false;
        int m2_leafIndex = -1;
        QString m2_requestId;
        bool m2_onChainConfirmed = false;
        double m2_elapsedSecs = 0.0;
        QString m2_rawLine;

        bool m3_active = false;
        int m3_epoch = 0;
        QString m3_nullifier;
        int m3_verifyCount = 0;
        QString m3_rawLine;
    };

    QString m_stateDir;
    int m_blockId = 0;
    NodeState m_nodes[4];
    ChatState m_sender;
    ChatState m_receiver;
    MarkerState m_markers;
    QDateTime m_membershipRequestTime;
    ChainEventModel m_chainEvents;
    ChainEventModel m_senderCorrelation;
    ChainEventModel m_nodeCorrelation;

    RpcClient* m_rpcClient = nullptr;
    LogTailer* m_seqTailer = nullptr;
    LogTailer* m_nodeTailers[4] = {};
    LogTailer* m_senderTailer = nullptr;
    LogTailer* m_receiverTailer = nullptr;
};
