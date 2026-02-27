//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

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
contract PropertyNFT is ERC721 {
    uint256 private _nextTokenId = 1;
    mapping(uint256 => bytes32) private _tokenMetadataHashes;

    event PropertyMinted(uint256 indexed tokenId, address indexed owner, bytes32 metadataHash);

    constructor() ERC721("LienFi Property", "PROP") {}

    /// @notice Mint a property NFT. The metadataHash is the keccak256 of the property details.
    function mint(bytes32 metadataHash) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _tokenMetadataHashes[tokenId] = metadataHash;
        _mint(msg.sender, tokenId);
        emit PropertyMinted(tokenId, msg.sender, metadataHash);
    }

    /// @notice Returns the property details hash stored as metadata for this token.
    function tokenMetadataHash(uint256 tokenId) external view returns (bytes32) {
        _requireOwned(tokenId);
        return _tokenMetadataHashes[tokenId];
    }
}
