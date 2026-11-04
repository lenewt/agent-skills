// E2E puppet and trace points (instrument-e2e). See E2ePuppet.h and references/protocol.md.
#ifdef E2E_PUPPET
#include "E2ePuppet.h"

#include <QCoreApplication>
#include <QFile>
#include <QLocalServer>
#include <QLocalSocket>
#include <QTextStream>
#include <exception>

Q_LOGGING_CATEGORY(e2e, "e2e")

namespace {
bool traceOn() { return qEnvironmentVariable("E2E_TRACE") == QLatin1String("1"); }
}

struct E2ePuppetAccess
{
    static E2ePuppet *&self() { static E2ePuppet *p = nullptr; return p; }
};

E2ePuppet::E2ePuppet(QObject *parent) : QObject(parent) {}

void E2ePuppet::trace(const QString &event, const QVariantMap &fields)
{
    if (!traceOn())
        return;
    QString line = QStringLiteral("E2E ") + event;
    for (auto it = fields.constBegin(); it != fields.constEnd(); ++it) {
        QString v = it.value().toString();
        if (v.isEmpty() || v.contains(QLatin1Char(' ')) || v.contains(QLatin1Char('"')))
            v = QLatin1Char('"') + v.replace(QLatin1Char('"'), QLatin1String("\\\"")) + QLatin1Char('"');
        line += QLatin1Char(' ') + it.key() + QLatin1Char('=') + v;
    }
    // Same logger as the product: category "e2e" goes through the installed message handler.
    qCInfo(e2e).noquote() << line;
}

void E2ePuppet::ready() { trace(QStringLiteral("ready")); }

QStringList E2ePuppet::split(const QString &line)
{
    QStringList out;
    QString cur;
    QChar quote;
    bool have = false;
    for (QChar c : line) {
        if (!quote.isNull()) {
            if (c == quote) quote = QChar(); else cur += c;
        } else if (c == QLatin1Char('"') || c == QLatin1Char('\'')) {
            quote = c; have = true;
        } else if (c.isSpace()) {
            if (have) { out << cur; cur.clear(); have = false; }
        } else {
            cur += c; have = true;
        }
    }
    if (have) out << cur;
    return out;
}

void E2ePuppet::add(const QString &name, const QString &argsSpec, const QString &description, Handler handler)
{
    if (!E2ePuppetAccess::self())
        E2ePuppetAccess::self() = new E2ePuppet(qApp);
    E2ePuppet *s = E2ePuppetAccess::self();
    if (!s->m_points.contains(name))
        s->m_order << name;
    s->m_points.insert(name, {argsSpec, description, std::move(handler)});
}

void E2ePuppet::start()
{
    const QString path = qEnvironmentVariable("E2E_PUPPET");
    if (path.isEmpty())
        return;
    if (!E2ePuppetAccess::self())
        E2ePuppetAccess::self() = new E2ePuppet(qApp);
    E2ePuppet *s = E2ePuppetAccess::self();
    s->m_server = new QLocalServer(s);
    s->m_server->setSocketOptions(QLocalServer::UserAccessOption);  // mode 0600
    QLocalServer::removeServer(path);                               // stale socket
    if (!s->m_server->listen(path)) {
        qCWarning(e2e) << "E2E puppet listen failed" << path << s->m_server->errorString();
        return;
    }
    connect(s->m_server, &QLocalServer::newConnection, s, &E2ePuppet::onConnection);
    trace(QStringLiteral("puppet-listening"), {{QStringLiteral("socket"), path}});
}

void E2ePuppet::onConnection()
{
    while (QLocalSocket *sock = m_server->nextPendingConnection()) {
        connect(sock, &QLocalSocket::disconnected, sock, &QObject::deleteLater);
        connect(sock, &QLocalSocket::readyRead, sock, [this, sock] {
            while (sock->canReadLine()) {
                const QString line = QString::fromUtf8(sock->readLine()).trimmed();
                if (line.isEmpty())
                    continue;
                sock->write((dispatch(line) + QLatin1Char('\n')).toUtf8());
                sock->flush();  // the reply must leave before a client half-close/disconnect
            }
        });
    }
}

QString E2ePuppet::dispatch(const QString &line)
{
    const QStringList tok = split(line);
    if (tok.isEmpty())
        return QStringLiteral("err empty request");
    const QString name = tok.first();
    QString reply;
    if (name == QLatin1String("help")) {
        QStringList parts;
        for (const QString &n : m_order)
            parts << (m_points[n].args.isEmpty() ? n : n + QLatin1Char(' ') + m_points[n].args) + QLatin1String(" - ") + m_points[n].desc;
        reply = QStringLiteral("ok ") + parts.join(QLatin1String(" | "));
    } else if (!m_points.contains(name)) {
        reply = QStringLiteral("err unknown point ") + name;
    } else {
        try {
            const QString data = m_points[name].fn(tok.mid(1));
            reply = data.isEmpty() ? QStringLiteral("ok") : QStringLiteral("ok ") + data;
        } catch (const std::exception &ex) {
            reply = QStringLiteral("err ") + QString::fromUtf8(ex.what());
        } catch (...) {
            reply = QStringLiteral("err handler failed");
        }
        reply.replace(QLatin1Char('\n'), QLatin1Char(' '));
    }
    trace(QStringLiteral("puppet"), {{QStringLiteral("point"), name},
                                     {QStringLiteral("reply"), reply.startsWith(QLatin1String("ok")) ? QStringLiteral("ok") : QStringLiteral("err")}});
    return reply;
}
#endif  // E2E_PUPPET
