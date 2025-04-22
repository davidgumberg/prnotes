https://github.com/bitcoin/bitcoin/pull/31250/commits/3841da0f62fa5e26f679a12c6efbafe1cb17c25f

```cpp
void TestGUIWatchOnly(interfaces::Node& node, TestChain100Setup& test)
{
    // [ Create a watch only wallet. ]
    const std::shared_ptr<CWallet>& wallet = SetupLegacyWatchOnlyWallet(node, test);

    // [ Three platform styles: windows, macos, other for everything else.. ]
    // Create widgets and init models
    std::unique_ptr<const PlatformStyle> platformStyle(PlatformStyle::instantiate("other"));
    // [ Interesting... minimal global state required for the gui? ]
    MiniGUI mini_gui(node, platformStyle.get());
    // [ Why are all the mini gui functions so hungry for the platform style? It should
    //   use other by default, and store the style. ]
    mini_gui.initModelForWallet(node, wallet, platformStyle.get());
    WalletModel& walletModel = *mini_gui.walletModel;
    SendCoinsDialog& sendCoinsDialog = mini_gui.sendCoinsDialog;

    // Update walletModel cached balance which will trigger an update for the 'labelBalance' QLabel.
    walletModel.pollBalanceChanged();
    // [ The model is needed to get the units of the label, otherwise compares arg 2,
    //   with what it can find in the label in arg3. ]
    // Check balance in send dialog
    CompareBalance(walletModel, walletModel.wallet().getBalances().watch_only_balance,
                   sendCoinsDialog.findChild<QLabel*>("labelBalance"));

    // Set change address
    sendCoinsDialog.getCoinControl()->destChange = GetDestinationForKey(test.coinbaseKey.GetPubKey(), OutputType::LEGACY);

    // [ To summarize, ugly but probably necessary hack, bc sendcoins locks the main thread,
    //   we can't dismiss the dialog after we send the coins, so set up a timer thread that checks every
    //   500 ms to dismiss the dialog. ]
    // Time to reject "save" PSBT dialog ('SendCoins' locks the main thread until the dialog receives the event).
    QTimer timer;
    timer.setInterval(500);
    QObject::connect(&timer, &QTimer::timeout, [&](){
        for (QWidget* widget : QApplication::topLevelWidgets()) {
            if (widget->inherits("QMessageBox") && widget->objectName().compare("psbt_copied_message") == 0) {
                QMessageBox* dialog = qobject_cast<QMessageBox*>(widget);
                QAbstractButton* button = dialog->button(QMessageBox::Discard);
                button->setEnabled(true);
                button->click();
                timer.stop();
                break;
            }
        }
    });
    timer.start(500);

    // Send tx and verify PSBT copied to the clipboard.
    SendCoins(*wallet.get(), sendCoinsDialog, PKHash(), 5 * COIN, /*rbf=*/false, QMessageBox::Save);
    const std::string& psbt_string = QApplication::clipboard()->text().toStdString();
    QVERIFY(!psbt_string.empty());

    // Decode psbt
    std::optional<std::vector<unsigned char>> decoded_psbt = DecodeBase64(psbt_string);
    QVERIFY(decoded_psbt);
    PartiallySignedTransaction psbt;
    std::string err;
    // [ Might be nice to validate the psbt data against the other information we have. This
    //   only checks that the PSBT can be decoded, pretty good. ]
    QVERIFY(DecodeRawPSBT(psbt, MakeByteSpan(*decoded_psbt), err));
}
```
