//
//  NCMediaCell.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 12/02/2019.
//  Copyright © 2019 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit

class NCMediaCell: UICollectionViewCell {
    @IBOutlet weak var imageItem: UIImageView!
    @IBOutlet weak var imageVisualEffect: UIVisualEffectView!
    @IBOutlet weak var imageSelect: UIImageView!
    @IBOutlet weak var imageStatus: UIImageView!

    let videoBadgeView = UIImageView()
    let videoCenterPlay = UIImageView()
    let selectionMark = UIImageView()
    var ocId: String = ""
    var date: Date?

    override func awakeFromNib() {
        super.awakeFromNib()
        setupVideoIndicators()
        initCell()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        initCell()
    }

    func initCell() {
        imageStatus.image = nil
        imageItem.image = nil
        videoBadgeView.isHidden = true
        videoCenterPlay.isHidden = true
        selectionMark.isHidden = true
        imageSelect.alpha = 0

        imageVisualEffect.isHidden = false
        imageVisualEffect.effect = nil
        imageVisualEffect.alpha = 0
        imageVisualEffect.isUserInteractionEnabled = false
        // PrivateCloud: selection dims the tile (gray-out) rather than a light tint.
        imageVisualEffect.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    }

    func selected(_ status: Bool, color: UIColor) {
        // PrivateCloud: selection = grayed-out tile + a large yellow check (clearer than the old tint).
        imageVisualEffect.alpha = status ? 1 : 0
        selectionMark.isHidden = !status
        imageSelect.alpha = 0
    }

    // PrivateCloud: make videos easy to tell apart from photos. A small marker sits in the
    // top-right corner of every video tile, and a larger centred play symbol is shown on
    // tiles big enough for it (the stock bottom-right play glyph alone was too subtle).
    private func setupVideoIndicators() {
        videoBadgeView.image = UIImage(systemName: "video.fill")
        videoBadgeView.tintColor = .white
        videoBadgeView.contentMode = .scaleAspectFit
        videoBadgeView.isHidden = true
        videoBadgeView.translatesAutoresizingMaskIntoConstraints = false
        videoBadgeView.layer.shadowColor = UIColor.black.cgColor
        videoBadgeView.layer.shadowOpacity = 0.6
        videoBadgeView.layer.shadowRadius = 2
        videoBadgeView.layer.shadowOffset = .zero

        videoCenterPlay.image = UIImage(systemName: "play.circle.fill")
        videoCenterPlay.tintColor = UIColor.white.withAlphaComponent(0.9)
        videoCenterPlay.contentMode = .scaleAspectFit
        videoCenterPlay.isHidden = true
        videoCenterPlay.translatesAutoresizingMaskIntoConstraints = false
        videoCenterPlay.layer.shadowColor = UIColor.black.cgColor
        videoCenterPlay.layer.shadowOpacity = 0.5
        videoCenterPlay.layer.shadowRadius = 3
        videoCenterPlay.layer.shadowOffset = .zero

        selectionMark.image = UIImage(systemName: "checkmark.circle.fill")
        selectionMark.tintColor = .systemYellow
        selectionMark.contentMode = .scaleAspectFit
        selectionMark.isHidden = true
        selectionMark.translatesAutoresizingMaskIntoConstraints = false
        selectionMark.layer.shadowColor = UIColor.black.cgColor
        selectionMark.layer.shadowOpacity = 0.6
        selectionMark.layer.shadowRadius = 3
        selectionMark.layer.shadowOffset = .zero

        contentView.addSubview(videoCenterPlay)
        contentView.addSubview(videoBadgeView)
        contentView.addSubview(selectionMark)

        NSLayoutConstraint.activate([
            videoBadgeView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            videoBadgeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            videoBadgeView.widthAnchor.constraint(equalToConstant: 18),
            videoBadgeView.heightAnchor.constraint(equalToConstant: 18),

            videoCenterPlay.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            videoCenterPlay.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            videoCenterPlay.widthAnchor.constraint(equalToConstant: 44),
            videoCenterPlay.heightAnchor.constraint(equalToConstant: 44),

            selectionMark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            selectionMark.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            selectionMark.widthAnchor.constraint(equalToConstant: 38),
            selectionMark.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    func setVideo(_ isVideo: Bool, largeTile: Bool) {
        videoBadgeView.isHidden = !isVideo
        videoCenterPlay.isHidden = !(isVideo && largeTile)
    }
}
