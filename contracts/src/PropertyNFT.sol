//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/**
 * @title PropertyNFT
 * @author LienFi Team
 *
 * Minimal ERC-721 for tokenized real estate. One token per property.
 * Anyone can mint. Each token stores a commitmentHash as its metadata —
 * the keccak256 of the property's full details (address, appraisal, docs, secret).
 *
 * Full property details live in the CRE enclave. The on-chain hash serves as
 * a tamper-proof anchor that CRE workflows verify off-chain.
 */
contract PropertyNFT is ERC721, Ownable {
    uint256 private _nextTokenId = 1;
    mapping(uint256 => bytes32) private _tokenMetadataHashes;

    address public minter;

    error PropertyNFT__NotMinter();
    error PropertyNFT__ZeroAddress();

    event PropertyMinted(
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 metadataHash
    );
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    constructor() ERC721("LienFi Property", "PROP") Ownable(msg.sender) {}

    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert PropertyNFT__ZeroAddress();
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }

    /// @notice Mint a property NFT. The metadataHash is the keccak256 of the property details.
    function mint(
        address to,
        bytes32 metadataHash
    ) external returns (uint256 tokenId) {
        if (msg.sender != minter) revert PropertyNFT__NotMinter();
        tokenId = _nextTokenId++;
        _tokenMetadataHashes[tokenId] = metadataHash;
        _mint(to, tokenId);
        emit PropertyMinted(tokenId, to, metadataHash);
    }

    /// @notice Returns the property details hash stored as metadata for this token.
    function tokenMetadataHash(
        uint256 tokenId
    ) external view returns (bytes32) {
        _requireOwned(tokenId);
        return _tokenMetadataHashes[tokenId];
    }
}
