// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721, ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721Royalty} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @notice Maybe - ERC721 American style covered calls & puts for ERC20 | ERC721 | ERC1155 tokens
 */
contract Maybe is ERC721Enumerable, ERC721Royalty {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    enum Category {
        CALL,
        PUT
    }

    struct Asset {
        bytes4 interfaceId;
        address contractAddress;
        uint256 tokenId;
        uint256 amount;
    }

    struct Option {
        Category category;
        address writer;
        Asset writerAsset;
        Asset ownerAsset;
        uint256 expiry;
    }

    Counters.Counter public id;
    mapping(uint256 => Option) public options;

    constructor(
        string memory name_,
        string memory symbol_,
        address royaltyRecipient_
    ) ERC721(name_, symbol_) {
        _setDefaultRoyalty(royaltyRecipient_, 100); // 1%
    }

    function mint(Option memory option) external returns (uint256) {
        uint256 currentId = id.current();
        options[currentId] = option;
        option.writer = _msgSender();
        option.writerAsset = _getInterfaceId(option.writerAsset);
        option.ownerAsset = _getInterfaceId(option.ownerAsset);
        bytes4 base;
        require(
            option.writerAsset.interfaceId != base,
            "Asset type of writerAsset is not supported"
        );
        require(
            option.ownerAsset.interfaceId != base,
            "Asset type of ownerAsset is not supported"
        );
        _transferAsset(_msgSender(), address(this), option.writerAsset);
        _safeMint(_msgSender(), currentId);
        id.increment();
        return currentId;
    }

    function burn(uint256 tokenId) external {
        Option memory option = options[tokenId];
        address sender = _msgSender();
        if (sender != ownerOf(tokenId)) {
            require(block.timestamp >= option.expiry, "Option not expired");
        } else {
            require(
                sender == option.writer,
                "Only writer can burn a non expired option"
            );
        }
        _transferAsset(address(this), option.writer, option.writerAsset);
        _burn(tokenId);
    }

    function exercize(uint256 tokenId) external {
        Option memory option = options[tokenId];
        address sender = _msgSender();
        require(ownerOf(tokenId) == sender, "Only owner can exercize");
        require(block.timestamp <= option.expiry, "Option expired");
        _transferAsset(sender, option.writer, option.ownerAsset);
        _transferAsset(address(this), sender, option.writerAsset);
        _burn(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, ERC721Royalty)
        returns (bool)
    {
        return
            ERC721Enumerable.supportsInterface(interfaceId) ||
            ERC721Royalty.supportsInterface(interfaceId);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721Royalty) {
        ERC721Royalty._burn(tokenId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override(ERC721, ERC721Enumerable) {
        ERC721Enumerable._beforeTokenTransfer(from, to, tokenId);
    }

    function _transferAsset(
        address src,
        address dst,
        Asset memory asset
    ) internal {
        if (asset.interfaceId == type(IERC20).interfaceId) {
            IERC20(asset.contractAddress).safeTransferFrom(
                src,
                dst,
                asset.amount
            );
        } else if (asset.interfaceId == type(IERC721).interfaceId) {
            IERC721(asset.contractAddress).safeTransferFrom(
                src,
                dst,
                asset.tokenId
            );
        } else if (asset.interfaceId == type(IERC1155).interfaceId) {
            bytes memory data;
            IERC1155(asset.contractAddress).safeTransferFrom(
                src,
                dst,
                asset.tokenId,
                asset.amount,
                data
            );
        }
    }

    function _getInterfaceId(Asset memory asset)
        internal
        view
        returns (Asset memory)
    {
        IERC165 assetInterface = IERC165(asset.contractAddress);
        if (assetInterface.supportsInterface(type(IERC20).interfaceId)) {
            asset.interfaceId = type(IERC20).interfaceId;
        } else if (
            assetInterface.supportsInterface(type(IERC721).interfaceId)
        ) {
            asset.interfaceId = type(IERC721).interfaceId;
        } else if (
            assetInterface.supportsInterface(type(IERC1155).interfaceId)
        ) {
            asset.interfaceId = type(IERC1155).interfaceId;
        }
        return asset;
    }
}
