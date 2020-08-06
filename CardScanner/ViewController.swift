//
//  ViewController.swift
//  CardScanner
//
//  Created by Andres Rojas on 6/08/20.
//

import UIKit

class ViewController: UIViewController {

    @IBAction func startScanning(_ sender: Any) {
        let viewController = CardScannerViewController()
        viewController.modalPresentationStyle = .overFullScreen
        present(viewController, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
    }
}

