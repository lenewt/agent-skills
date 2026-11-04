// E2E puppet and trace points (instrument-e2e). Qt5/Qt6. Whole content is gated by E2E_PUPPET.
// Without the flag every call below compiles to nothing, so call sites need no #ifdef.
#pragma once

#ifdef E2E_PUPPET
#include <QHash>
#include <QLoggingCategory>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>
#include <functional>

Q_DECLARE_LOGGING_CATEGORY(e2e)

class QLocalServer;

class E2ePuppet : public QObject
{
public:
    // Handler runs on the thread that called start() (the GUI thread). Return data or "".
    // Throw std::exception or return nothing special; an exception becomes "err <message>".
    using Handler = std::function<QString(const QStringList &args)>;

    // Registers a point. argsSpec is shown by `help`, e.g. "TYPE [N]".
    static void add(const QString &name, const QString &argsSpec, const QString &description, Handler handler);
    // Starts the server when env E2E_PUPPET holds a socket path. Call once, after QCoreApplication exists.
    static void start();
    // Logs "E2E <event> k=v ..." when E2E_TRACE=1.
    static void trace(const QString &event, const QVariantMap &fields = {});
    // Logs "E2E ready". Call once the UI accepts input.
    static void ready();

    // Splits `point arg "quoted arg"` into tokens. Exposed for tests.
    static QStringList split(const QString &line);

private:
    explicit E2ePuppet(QObject *parent = nullptr);
    void onConnection();
    QString dispatch(const QString &line);
    struct Point { QString args, desc; Handler fn; };
    QHash<QString, Point> m_points;
    QStringList m_order;
    QLocalServer *m_server = nullptr;
    friend struct E2ePuppetAccess;
};

#define E2E_ADD(name, spec, desc, ...) E2ePuppet::add((name), (spec), (desc), __VA_ARGS__)
#define E2E_START() E2ePuppet::start()
#define E2E_TRACE(event, ...) E2ePuppet::trace((event), ##__VA_ARGS__)
#define E2E_READY() E2ePuppet::ready()

#else  // no E2E_PUPPET: nothing is compiled in, nothing is linked

#define E2E_ADD(name, spec, desc, ...) ((void)0)
#define E2E_START() ((void)0)
#define E2E_TRACE(event, ...) ((void)0)
#define E2E_READY() ((void)0)

#endif
