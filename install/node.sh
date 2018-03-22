#!/bin/bash

# Install latest node
nodenv install --list
nodenv install 9.8.0
nodenv global 9.8.0
nodenv rehash

npm update -g
